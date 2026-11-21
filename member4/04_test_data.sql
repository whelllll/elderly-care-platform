/* ============================================================
   M4 测试数据：monitor_device / vital_sign / emergency_event 各 20 条
   ------------------------------------------------------------
   关联方式：
     - 老人：从 elder_profile 按 id_card_no 取前 20 条，使用实际 elder_id；
     - 设备：device_sn 前缀 M4TEST-，device_id 由 IDENTITY 生成；
     - 体征：按 device_sn 回查实际 device_id / elder_id；
     - 响应人：按 username 取 comm_admin / org_mgr 及 caregiver_% 账号，不写死 user_id；
       街道/民政监管只读，不作为响应人。
   重复执行：
     - 已存在 M4TEST- 设备时直接跳过，不重复插入；
   失败处理：
     - 整个脚本包在事务中，任一步失败全部回滚。
   ============================================================ */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID(N'dbo.elder_profile', N'U') IS NULL
    THROW 52001, N'缺少 dbo.elder_profile，请先执行成员1 建表脚本。', 1;

IF OBJECT_ID(N'dbo.sys_user', N'U') IS NULL
    THROW 52002, N'缺少 dbo.sys_user，请先执行成员4 的 09_sys_user.sql。', 1;

IF OBJECT_ID(N'dbo.monitor_device', N'U') IS NULL
    THROW 52003, N'缺少 dbo.monitor_device，请先执行成员4 的 01_schema.sql。', 1;

IF OBJECT_ID(N'dbo.vital_sign', N'U') IS NULL
    THROW 52004, N'缺少 dbo.vital_sign，请先执行成员4 的 01_schema.sql。', 1;

IF OBJECT_ID(N'dbo.emergency_event', N'U') IS NULL
    THROW 52005, N'缺少 dbo.emergency_event，请先执行成员4 的 01_schema.sql。', 1;
GO

IF EXISTS (SELECT 1 FROM dbo.monitor_device WHERE device_sn LIKE N'M4TEST-%')
BEGIN
    PRINT N'M4 测试数据已存在（M4TEST- 设备），跳过本次插入。';
    RETURN;
END;
GO

BEGIN TRY
    BEGIN TRANSACTION;

    /* 1. 取实际老人，不写死 elder_id */
    DECLARE @elder TABLE
    (
        seq      INT IDENTITY(1,1) PRIMARY KEY,
        elder_id INT NOT NULL
    );

    INSERT INTO @elder (elder_id)
    SELECT TOP (20) elder_id
    FROM dbo.elder_profile
    WHERE archive_status = N'正常'
    ORDER BY id_card_no;

    IF (SELECT COUNT(*) FROM @elder) < 20
        THROW 52010, N'老人档案不足 20 条，无法生成 M4 测试数据。', 1;

    /* 2. 设备：device_sn 用 M4TEST- 前缀，device_id 由 IDENTITY 生成 */
    DECLARE @device TABLE
    (
        seq       INT IDENTITY(1,1) PRIMARY KEY,
        device_sn NVARCHAR(50) NOT NULL,
        elder_id  INT NOT NULL
    );

    INSERT INTO @device (device_sn, elder_id)
    SELECT
        N'M4TEST-DEV-' + RIGHT('000' + CONVERT(VARCHAR(3), seq), 3),
        elder_id
    FROM @elder;

    INSERT INTO dbo.monitor_device
        (elder_id, device_type, install_position, bind_time,
         unbind_time, device_status, device_sn)
    SELECT
        d.elder_id,
        CASE ((d.seq - 1) % 4)
            WHEN 0 THEN N'血压计'
            WHEN 1 THEN N'心电贴'
            WHEN 2 THEN N'跌倒雷达'
            ELSE N'一键呼叫'
        END,
        CASE ((d.seq - 1) % 4)
            WHEN 0 THEN N'卧室床头'
            WHEN 1 THEN N'客厅电视柜'
            WHEN 2 THEN N'卫生间门口'
            ELSE N'玄关'
        END,
        DATEADD(DAY, -30 - d.seq, SYSDATETIME()),
        CASE WHEN d.seq <= 4 THEN DATEADD(DAY, -5, SYSDATETIME()) ELSE NULL END,
        CASE
            WHEN d.seq IN (2, 4) THEN N'报废'
            WHEN d.seq IN (5, 6) THEN N'故障'
            ELSE N'正常'
        END,
        d.device_sn
    FROM @device AS d;

    /* 3. 体征：按 device_sn 回查实际 device_id / elder_id */
    ;WITH metric AS
    (
        SELECT *
        FROM (VALUES
            (1, N'收缩压', N'128 mmHg', 0),
            (2, N'舒张压', N'82 mmHg',  0),
            (3, N'心率',   N'76 次/分', 0),
            (4, N'血氧',   N'98 %',     0),
            (5, N'跌倒告警', N'0',      0),
            (6, N'收缩压', N'145 mmHg', 1),
            (7, N'舒张压', N'95 mmHg',  1),
            (8, N'心率',   N'105 次/分', 1),
            (9, N'血氧',   N'91 %',     1),
            (10, N'跌倒告警', N'1',     1)
        ) AS v(rn, indicator_type, indicator_value, is_abnormal)
    )
    INSERT INTO dbo.vital_sign
        (device_id, elder_id, collect_time, indicator_type,
         indicator_value, is_abnormal, data_source)
    SELECT
        md.device_id,
        d.elder_id,
        CASE
            WHEN d.seq <= 4 THEN DATEADD(DAY, -10, SYSDATETIME())
            ELSE DATEADD(HOUR, -d.seq, SYSDATETIME())
        END,
        m.indicator_type,
        m.indicator_value,
        m.is_abnormal,
        CASE WHEN d.seq <= 15 THEN N'设备自动上传' ELSE N'人工录入' END
    FROM @device AS d
    INNER JOIN dbo.monitor_device AS md ON md.device_sn = d.device_sn
    INNER JOIN metric AS m ON m.rn = ((d.seq - 1) % 10) + 1;

    /* 4. 响应人：按 username 取实际 user_id；只取社区/机构/护理员 */
    DECLARE @responder TABLE
    (
        rn      INT PRIMARY KEY,
        user_id INT NOT NULL
    );

    INSERT INTO @responder (rn, user_id)
    SELECT
        ROW_NUMBER() OVER (
            ORDER BY CASE
                WHEN username = N'comm_admin' THEN 1
                WHEN username = N'org_mgr'    THEN 2
                ELSE 3
            END,
            username
        ),
        user_id
    FROM dbo.sys_user
    WHERE username IN (N'comm_admin', N'org_mgr')
       OR username LIKE N'caregiver[_]%';

    IF (SELECT COUNT(*) FROM @responder) < 4
        THROW 52011, N'sys_user 缺少响应人账号：需要 comm_admin、org_mgr，以及 12 号脚本生成的 caregiver_% 账号。', 1;

    /* 5. 应急事件：老人、响应人都用实际数据 */
    ;WITH base AS
    (
        SELECT
            d.seq,
            d.elder_id,
            DATEADD(HOUR, -d.seq, SYSDATETIME()) AS happen_time
        FROM @device AS d
    ),
    ev AS
    (
        SELECT
            b.seq,
            b.elder_id,
            b.happen_time,
            CASE ((b.seq - 1) % 3)
                WHEN 0 THEN N'一般'
                WHEN 1 THEN N'重要'
                ELSE N'紧急'
            END AS event_level,
            CASE ((b.seq - 1) % 3)
                WHEN 0 THEN N'设备告警'
                WHEN 1 THEN N'家属呼叫'
                ELSE N'主动上报'
            END AS trigger_source,
            CASE
                WHEN b.seq <= 6 OR b.seq >= 19 THEN N'已闭环'
                WHEN b.seq BETWEEN 7 AND 10 THEN N'处置中'
                WHEN b.seq BETWEEN 11 AND 16 THEN N'待响应'
                ELSE N'已误报'
            END AS event_status
        FROM base AS b
    )
    INSERT INTO dbo.emergency_event
        (elder_id, trigger_source, event_level, happen_time, response_deadline,
         responder_id, arrive_time, event_status, dispose_result, close_time)
    SELECT
        ev.elder_id,
        ev.trigger_source,
        ev.event_level,
        ev.happen_time,
        DATEADD
        (
            MINUTE,
            CASE ev.event_level
                WHEN N'紧急' THEN 15
                WHEN N'重要' THEN 60
                ELSE 120
            END,
            ev.happen_time
        ),
        CASE
            WHEN ev.event_status IN (N'已闭环', N'处置中') THEN r.user_id
            ELSE NULL
        END,
        CASE
            WHEN ev.event_status IN (N'已闭环', N'处置中')
                THEN DATEADD(MINUTE, 10, ev.happen_time)
            ELSE NULL
        END,
        ev.event_status,
        CASE
            WHEN ev.event_status = N'已闭环' THEN N'已现场处置，老人状态稳定'
            WHEN ev.event_status = N'已误报' THEN N'误报：设备误触发，已现场核实'
            ELSE NULL
        END,
        CASE
            WHEN ev.event_status = N'已闭环'
                THEN DATEADD(MINUTE, 35, ev.happen_time)
            ELSE NULL
        END
    FROM ev
    LEFT JOIN @responder AS r ON r.rn = ((ev.seq - 1) % 4) + 1;

    COMMIT TRANSACTION;

    SELECT N'monitor_device' AS table_name, COUNT(*) AS row_count
    FROM dbo.monitor_device
    WHERE device_sn LIKE N'M4TEST-%'
    UNION ALL
    SELECT N'vital_sign', COUNT(*)
    FROM dbo.vital_sign AS v
    INNER JOIN dbo.monitor_device AS d ON d.device_id = v.device_id
    WHERE d.device_sn LIKE N'M4TEST-%'
    UNION ALL
    SELECT N'emergency_event', COUNT(*)
    FROM dbo.emergency_event;

    PRINT N'M4 测试数据插入完成（失败会整体回滚）。';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
