/* ============================================================
   视图：当前设备、最近一次体征、未闭环事件
   ============================================================ */

/* 1. 老人当前仍绑定的设备 */
CREATE OR ALTER VIEW dbo.v_elder_device_active
AS
SELECT
    d.device_id,
    d.elder_id,
    e.elder_name,
    d.device_type,
    d.device_sn,
    d.install_position,
    d.device_status,
    d.bind_time
FROM dbo.monitor_device AS d
INNER JOIN dbo.elder_profile AS e ON e.elder_id = d.elder_id
WHERE d.unbind_time IS NULL;
GO

/* 2. 每位老人每个指标最近一次体征 */
CREATE OR ALTER VIEW dbo.v_elder_latest_vital
AS
WITH ranked AS
(
    SELECT
        v.vital_id,
        v.elder_id,
        e.elder_name,
        v.device_id,
        d.device_sn,
        v.collect_time,
        v.indicator_type,
        v.indicator_value,
        v.is_abnormal,
        v.data_source,
        ROW_NUMBER() OVER (
            PARTITION BY v.elder_id, v.indicator_type
            ORDER BY v.collect_time DESC, v.vital_id DESC
        ) AS rn
    FROM dbo.vital_sign AS v
    INNER JOIN dbo.elder_profile AS e ON e.elder_id = v.elder_id
    INNER JOIN dbo.monitor_device AS d ON d.device_id = v.device_id
)
SELECT
    vital_id, elder_id, elder_name, device_id, device_sn,
    collect_time, indicator_type, indicator_value, is_abnormal, data_source
FROM ranked
WHERE rn = 1;
GO

/* 3. 未闭环事件及剩余响应时间 */
CREATE OR ALTER VIEW dbo.v_open_emergency
AS
SELECT
    ev.event_id,
    ev.elder_id,
    e.elder_name,
    ev.trigger_source,
    ev.event_level,
    ev.happen_time,
    ev.response_deadline,
    ev.event_status,
    ev.responder_id,
    u.real_name AS responder_name,
    DATEDIFF(MINUTE, SYSDATETIME(), ev.response_deadline) AS remaining_minutes,
    CASE
        WHEN ev.event_status = N'待响应' AND ev.response_deadline < SYSDATETIME() THEN 1
        ELSE 0
    END AS is_overdue
FROM dbo.emergency_event AS ev
INNER JOIN dbo.elder_profile AS e ON e.elder_id = ev.elder_id
LEFT JOIN dbo.sys_user AS u ON u.user_id = ev.responder_id
WHERE ev.event_status IN (N'待响应', N'处置中');
GO


/* ============================================================
   存储过程：登记、接单、闭环
   ============================================================ */

/* 1. 登记应急事件：按等级写 response_deadline */
CREATE OR ALTER PROCEDURE dbo.sp_raise_emergency
    @elder_id       INT,
    @trigger_source NVARCHAR(20),
    @event_level    NVARCHAR(10),
    @happen_time    DATETIME2(0),
    @event_id       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.elder_profile WHERE elder_id = @elder_id)
    BEGIN
        ;THROW 51001, N'老人档案不存在。', 1;
    END;

    IF @trigger_source IS NULL
       OR @trigger_source NOT IN (N'设备告警', N'家属呼叫', N'主动上报')
    BEGIN
        ;THROW 51002, N'触发来源不合法。', 1;
    END;

    IF @event_level IS NULL
       OR @event_level NOT IN (N'一般', N'重要', N'紧急')
    BEGIN
        ;THROW 51003, N'事件等级不合法。', 1;
    END;

    IF @happen_time IS NULL
    BEGIN
        ;THROW 51004, N'发生时间不能为空。', 1;
    END;

    DECLARE @minutes INT =
        CASE @event_level
            WHEN N'紧急' THEN 15
            WHEN N'重要' THEN 60
            ELSE 120
        END;

    INSERT INTO dbo.emergency_event
        (elder_id, trigger_source, event_level, happen_time, response_deadline, event_status)
    VALUES
        (@elder_id, @trigger_source, @event_level, @happen_time,
         DATEADD(MINUTE, @minutes, @happen_time), N'待响应');

    SET @event_id = CONVERT(INT, SCOPE_IDENTITY());
END;
GO

/* 2. 接单：待响应 -> 处置中，分配响应人 */
CREATE OR ALTER PROCEDURE dbo.sp_accept_emergency
    @event_id     INT,
    @responder_id INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.sys_user WHERE user_id = @responder_id)
    BEGIN
        ;THROW 51021, N'响应人账号不存在。', 1;
    END;

    UPDATE dbo.emergency_event
    SET event_status = N'处置中',
        responder_id = @responder_id,
        updated_at   = SYSDATETIME()
    WHERE event_id = @event_id
      AND event_status = N'待响应';

    IF @@ROWCOUNT = 0
    BEGIN
        ;THROW 51022, N'事件不存在或不是待响应状态。', 1;
    END;
END;
GO

/* 3. 闭环事件：只允许处置中，且必须有到场时间/处置结果 */
CREATE OR ALTER PROCEDURE dbo.sp_close_emergency
    @event_id       INT,
    @arrive_time    DATETIME2(0),
    @dispose_result NVARCHAR(255)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @status NVARCHAR(10), @happen DATETIME2(0);

    SELECT @status = event_status, @happen = happen_time
    FROM dbo.emergency_event
    WHERE event_id = @event_id;

    IF @status IS NULL
    BEGIN
        ;THROW 51011, N'事件不存在。', 1;
    END;

    IF @status <> N'处置中'
    BEGIN
        ;THROW 51012, N'只有处置中的事件才能闭环。', 1;
    END;

    IF @arrive_time IS NULL OR @arrive_time < @happen
    BEGIN
        ;THROW 51013, N'到场时间不能为空，且不得早于发生时间。', 1;
    END;

    IF @dispose_result IS NULL OR LEN(LTRIM(RTRIM(@dispose_result))) = 0
    BEGIN
        ;THROW 51014, N'处置结果不能为空。', 1;
    END;

    IF SYSDATETIME() < @happen
    BEGIN
        ;THROW 51015, N'闭环时间不能早于发生时间。', 1;
    END;

    UPDATE dbo.emergency_event
    SET event_status   = N'已闭环',
        arrive_time    = @arrive_time,
        dispose_result = @dispose_result,
        close_time     = SYSDATETIME(),
        updated_at     = SYSDATETIME()
    WHERE event_id = @event_id;
END;
GO
