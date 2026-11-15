SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
-- 创建订单，并把项目价格与时长写入订单快照。
CREATE OR ALTER PROCEDURE dbo.usp_M2_CreateOrder
    @ElderID INT,
    @ServiceID INT,
    @AppointmentTime DATETIME2(0),
    @ServiceAddress NVARCHAR(200),
    @OrderID INT OUTPUT,
    @Latitude DECIMAL(10,7) = NULL,
    @Longitude DECIMAL(10,7) = NULL,
    @RadiusM INT = NULL,
    @Remark NVARCHAR(255) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @own_transaction BIT = IIF(@@TRANCOUNT = 0, 1, 0);
    SET @OrderID = NULL;
    BEGIN TRY
        IF @own_transaction = 1 BEGIN TRAN;
        DECLARE @price DECIMAL(10,2), @duration INT, @now DATETIME2(0) = SYSDATETIME();
        SELECT @price = price, @duration = duration
        FROM dbo.service_item WITH (HOLDLOCK) WHERE service_id = @ServiceID AND status = N'上架';
        IF @duration IS NULL THROW 51100, N'服务项目不存在或未上架。', 1;
        IF @AppointmentTime IS NULL OR @AppointmentTime < @now
            THROW 51101, N'预约时间不能早于下单时间。', 1;

        INSERT dbo.service_order (
            elder_id, service_id, order_time, appointment_time, total_amount, remark, duration_minutes,
            service_address, service_latitude, service_longitude, allowed_radius_m
        )
        VALUES (@ElderID, @ServiceID, @now, @AppointmentTime, @price, @Remark, @duration,
                @ServiceAddress, @Latitude, @Longitude, @RadiusM);
        SET @OrderID = CONVERT(INT, SCOPE_IDENTITY());
        IF @own_transaction = 1 COMMIT;
    END TRY
    BEGIN CATCH
        SET @OrderID = NULL;
        IF @own_transaction = 1 AND XACT_STATE() <> 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO
-- 执行订单与派单的原子状态变更。护工签到、签退和审核由成员3写入 work_record。
CREATE OR ALTER PROCEDURE dbo.usp_M2_OrderAction
    @OrderID INT,
    @Action VARCHAR(12),
    @CaregiverID INT = NULL,
    @DispatchID INT = NULL OUTPUT,
    @Reason NVARCHAR(255) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET ANSI_PADDING ON;
    SET ANSI_WARNINGS ON;
    SET ARITHABORT ON;
    SET CONCAT_NULL_YIELDS_NULL ON;
    SET NUMERIC_ROUNDABORT OFF;

    DECLARE @own_transaction BIT = IIF(@@TRANCOUNT = 0, 1, 0),
            @requested_dispatch INT = @DispatchID;
    SET @DispatchID = NULL;

    BEGIN TRY
        IF @own_transaction = 1 BEGIN TRAN;

        -- 课程设计采用数据库内的单一事务锁，串行化经本过程提交的派单与状态变更。
        DECLARE @lock_result INT;
        EXEC @lock_result = sys.sp_getapplock
            @Resource = N'M2.OrderAction.v1', @LockMode = N'Exclusive',
            @LockOwner = N'Transaction', @LockTimeout = 10000;
        IF @lock_result < 0 THROW 51102, N'派单事务锁获取失败，请重试。', 1;

        DECLARE @status NVARCHAR(20), @service_id INT, @start DATETIME2(0), @finish DATETIME2(0),
                @address NVARCHAR(200), @active_id INT, @active_state NVARCHAR(20),
                @active_caregiver INT, @now DATETIME2(0) = SYSDATETIME();
        SELECT @status = order_status, @service_id = service_id, @start = appointment_time,
               @finish = DATEADD(MINUTE, duration_minutes, appointment_time), @address = service_address
        FROM dbo.service_order WITH (UPDLOCK, HOLDLOCK)
        WHERE order_id = @OrderID;

        IF @status IS NULL THROW 51103, N'订单不存在。', 1;
        IF @Action IS NULL OR @Action NOT IN
            ('DISPATCH','REASSIGN','ACCEPT','REJECT','WITHDRAW','CANCEL','START','COMPLETE')
            THROW 51104, N'未知操作。', 1;
        IF @status IN (N'已完成', N'已取消')
            THROW 51105, N'已完成或已取消订单不能继续流转。', 1;

        SELECT @active_id = dispatch_id, @active_state = dispatch_status, @active_caregiver = caregiver_id
        FROM dbo.dispatch_record WITH (UPDLOCK, HOLDLOCK)
        WHERE order_id = @OrderID AND dispatch_status IN (N'待接单', N'已接单');

        IF @Action IN ('REASSIGN','ACCEPT','REJECT','WITHDRAW','START','COMPLETE')
            AND (@requested_dispatch IS NULL OR @active_id IS NULL OR @active_id <> @requested_dispatch)
            THROW 51106, N'请提供该订单当前有效派单的编号。', 1;

        IF @Action IN ('REASSIGN','REJECT','WITHDRAW','CANCEL')
        BEGIN
            IF @status NOT IN (N'待派单', N'待接单', N'待服务')
                OR (@Action <> 'CANCEL' AND @status NOT IN (N'待接单', N'待服务'))
                OR (@Action = 'REJECT' AND (@status <> N'待接单' OR @active_state <> N'待接单'))
                OR EXISTS (SELECT 1 FROM dbo.work_record WITH (UPDLOCK, HOLDLOCK)
                           WHERE dispatch_id = @active_id)
                THROW 51107, N'当前状态不能拒单、撤回、改派或取消，已有签到时也不可执行。', 1;

            UPDATE dbo.dispatch_record
            SET dispatch_status = IIF(@Action = 'REJECT', N'已拒绝', N'已撤回'),
                remark = COALESCE(@Reason, remark)
            WHERE dispatch_id = @active_id;
            UPDATE dbo.service_order
            SET order_status = IIF(@Action = 'CANCEL', N'已取消', N'待派单')
            WHERE order_id = @OrderID;

            IF @Action <> 'REASSIGN' SET @DispatchID = @active_id;
        END;

        IF @Action IN ('DISPATCH','REASSIGN')
        BEGIN
            IF @Action = 'DISPATCH' AND (@status <> N'待派单' OR @active_id IS NOT NULL)
                THROW 51108, N'只有无有效派单的待派单订单可以派单。', 1;

            IF NOT EXISTS (SELECT 1 FROM dbo.service_item WITH (HOLDLOCK)
                           WHERE service_id = @service_id AND status = N'上架')
                THROW 51100, N'服务项目不存在或未上架。', 1;

            DECLARE @area NVARCHAR(200), @community NVARCHAR(200) =
                LEFT(@address, CHARINDEX(N'-', (@address + N'-') COLLATE Latin1_General_100_BIN2) - 1);
            SELECT @area = service_area FROM dbo.caregiver WITH (UPDLOCK, HOLDLOCK)
            WHERE caregiver_id = @CaregiverID AND employment_status = N'在岗';
            IF @area IS NULL THROW 51109, N'护工不存在或不在岗。', 1;
            IF CHARINDEX(N'-', @address COLLATE Latin1_General_100_BIN2) <= 1 OR @area COLLATE Latin1_General_100_BIN2 <> @community COLLATE Latin1_General_100_BIN2
                OR DATALENGTH(@area) <> DATALENGTH(@community)
                THROW 51110, N'订单社区与护工服务区域不匹配，请重新选择护工。', 1;

            IF NOT EXISTS (
                SELECT 1 FROM dbo.caregiver_certificate WITH (UPDLOCK, HOLDLOCK)
                WHERE caregiver_id = @CaregiverID AND service_id = @service_id
                    AND certificate_status = N'有效' AND CONVERT(DATE, @start) BETWEEN valid_from AND valid_to
            ) THROW 51111, N'护工没有覆盖预约日期的有效项目资质。', 1;

            DECLARE @schedule_id INT, @shift_start DATETIME2(0), @shift_end DATETIME2(0),
                    @max_orders INT, @schedule_count INT;
            SELECT @schedule_count = COUNT(*), @schedule_id = MAX(schedule_id), @max_orders = MAX(max_orders),
                   @shift_start = MAX(start_time), @shift_end = MAX(end_time)
            FROM dbo.caregiver_schedule WITH (UPDLOCK, HOLDLOCK)
            WHERE caregiver_id = @CaregiverID AND schedule_status = N'开放'
                AND start_time <= @start AND @finish <= end_time;
            IF @schedule_count <> 1 THROW 51112, N'预约必须恰好落在一个开放班次内。', 1;
            IF EXISTS (SELECT 1 FROM dbo.caregiver_schedule WITH (UPDLOCK, HOLDLOCK)
                       WHERE caregiver_id = @CaregiverID AND schedule_status <> N'取消'
                         AND schedule_id <> @schedule_id AND start_time < @shift_end AND @shift_start < end_time)
                THROW 51112, N'候选班次与该护工的其他未取消班次重叠。', 1;

            IF EXISTS (
                SELECT 1 FROM dbo.dispatch_record AS d WITH (UPDLOCK, HOLDLOCK)
                JOIN dbo.service_order AS o WITH (UPDLOCK, HOLDLOCK) ON o.order_id = d.order_id
                WHERE d.caregiver_id = @CaregiverID AND d.dispatch_status IN (N'待接单', N'已接单')
                    AND o.appointment_time < @finish
                    AND @start < DATEADD(MINUTE, o.duration_minutes, o.appointment_time)
            ) THROW 51113, N'护工已有时间重叠的有效派单。', 1;

            IF (SELECT COUNT_BIG(*)
                FROM dbo.dispatch_record AS d WITH (UPDLOCK, HOLDLOCK)
                JOIN dbo.service_order AS o WITH (UPDLOCK, HOLDLOCK) ON o.order_id = d.order_id
                LEFT JOIN dbo.work_record AS w WITH (UPDLOCK, HOLDLOCK) ON w.dispatch_id = d.dispatch_id
                WHERE d.caregiver_id = @CaregiverID AND d.dispatch_status IN (N'待接单', N'已接单')
                    AND (w.schedule_id = @schedule_id
                        OR (w.schedule_id IS NULL AND @shift_start <= o.appointment_time
                            AND DATEADD(MINUTE, o.duration_minutes, o.appointment_time) <= @shift_end))
            ) >= @max_orders THROW 51114, N'班次累计接单量已达上限。', 1;

            INSERT dbo.dispatch_record (order_id, caregiver_id, dispatch_time, remark)
            VALUES (@OrderID, @CaregiverID, @now, IIF(@Action = 'DISPATCH', @Reason, NULL));
            SET @DispatchID = CONVERT(INT, SCOPE_IDENTITY());
            UPDATE dbo.service_order SET order_status = N'待接单' WHERE order_id = @OrderID;
        END;

        IF @Action = 'ACCEPT'
        BEGIN
            IF @status <> N'待接单' OR @active_state <> N'待接单'
                THROW 51115, N'只有待接单派单可以接单。', 1;
            UPDATE dbo.dispatch_record SET dispatch_status = N'已接单',
                accept_time = IIF(@now < dispatch_time, dispatch_time, @now)
            WHERE dispatch_id = @active_id;
            UPDATE dbo.service_order SET order_status = N'待服务' WHERE order_id = @OrderID;
            SET @DispatchID = @active_id;
        END;

        IF @Action IN ('START','COMPLETE')
        BEGIN
            IF @active_state <> N'已接单'
                OR (@Action = 'START' AND @status <> N'待服务')
                OR (@Action = 'COMPLETE' AND @status <> N'服务中')
                THROW 51116, N'订单或派单的状态不允许开始或完成服务。', 1;

            IF NOT EXISTS (
                SELECT 1 FROM dbo.work_record AS w WITH (UPDLOCK, HOLDLOCK)
                JOIN dbo.caregiver_schedule AS s WITH (UPDLOCK, HOLDLOCK) ON s.schedule_id = w.schedule_id
                WHERE w.dispatch_id = @active_id AND s.caregiver_id = @active_caregiver
                    AND s.start_time <= @start AND @finish <= s.end_time
                    AND (@Action = 'START' OR (w.check_out_time > w.check_in_time AND w.review_status = N'通过'
                         AND w.effective_minutes IS NOT NULL))
            ) THROW 51117, N'开始服务需有匹配班次的签到，完成服务还需签退及成员3审核通过。', 1;
            UPDATE dbo.service_order
            SET order_status = IIF(@Action = 'START', N'服务中', N'已完成')
            WHERE order_id = @OrderID;
            SET @DispatchID = @active_id;
        END;

        IF @own_transaction = 1 COMMIT;
    END TRY
    BEGIN CATCH
        SET @DispatchID = NULL;
        IF @own_transaction = 1 AND XACT_STATE() <> 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO
-- 成员3可用作签到位置校验入口，由成员3保存结果及管理人工审核。
CREATE OR ALTER PROCEDURE dbo.usp_M2_CheckFence
    @OrderID INT,
    @Location NVARCHAR(200),
    @FenceResult NVARCHAR(10) OUTPUT,
    @DistanceM FLOAT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @FenceResult = N'待校验';
    SET @DistanceM = NULL;

    DECLARE @service_lat DECIMAL(10,7), @service_lon DECIMAL(10,7), @radius INT;
    SELECT @service_lat = service_latitude, @service_lon = service_longitude, @radius = allowed_radius_m
    FROM dbo.service_order WHERE order_id = @OrderID;
    DECLARE @comma INT = CHARINDEX(N',', @Location COLLATE Latin1_General_100_BIN2);
    IF @radius IS NULL OR @service_lat IS NULL OR @service_lon IS NULL
        OR @comma IS NULL OR @comma <= 1 OR CHARINDEX(N',', @Location COLLATE Latin1_General_100_BIN2, @comma + 1) > 0 RETURN;

    DECLARE @components TABLE (part INT PRIMARY KEY, coordinate NVARCHAR(200) NOT NULL);
    INSERT @components VALUES (1, LEFT(@Location, @comma-1)), (2, SUBSTRING(@Location, @comma+1, 200));
    IF EXISTS (
        SELECT 1 FROM @components
        CROSS APPLY (VALUES (CASE WHEN LEFT(coordinate, 1) COLLATE Latin1_General_100_BIN2 IN (N'-', N'+')
                             THEN SUBSTRING(coordinate, 2, 200) ELSE coordinate END)) AS c(unsigned_coordinate)
        CROSS APPLY (VALUES (CHARINDEX(N'.', c.unsigned_coordinate COLLATE Latin1_General_100_BIN2))) AS p(decimal_at)
        WHERE c.unsigned_coordinate COLLATE Latin1_General_100_BIN2 NOT LIKE N'[0-9]%'
            OR c.unsigned_coordinate COLLATE Latin1_General_100_BIN2 LIKE N'%[^0-9.]%'
            OR DATALENGTH(c.unsigned_coordinate) <> DATALENGTH(RTRIM(c.unsigned_coordinate))
            OR (p.decimal_at > 0 AND (CHARINDEX(N'.', c.unsigned_coordinate COLLATE Latin1_General_100_BIN2, p.decimal_at + 1) > 0
                OR LEN(c.unsigned_coordinate) - p.decimal_at NOT BETWEEN 1 AND 7))
    ) RETURN;

    DECLARE @lat DECIMAL(10,7), @lon DECIMAL(10,7);
    SELECT @lat = TRY_CONVERT(DECIMAL(10,7), coordinate) FROM @components WHERE part = 1;
    SELECT @lon = TRY_CONVERT(DECIMAL(10,7), coordinate) FROM @components WHERE part = 2;
    IF @lat IS NULL OR @lon IS NULL OR @lat NOT BETWEEN -90 AND 90 OR @lon NOT BETWEEN -180 AND 180 RETURN;

    BEGIN TRY
        DECLARE @actual geography = geography::Point(@lat, @lon, 4326);
        DECLARE @target geography = geography::Point(@service_lat, @service_lon, 4326);
        SET @DistanceM = @actual.STDistance(@target);
        IF @DistanceM IS NOT NULL
            SET @FenceResult = IIF(@DistanceM <= @radius, N'通过', N'未通过');
    END TRY
    BEGIN CATCH
        SET @FenceResult = N'待校验';
        SET @DistanceM = NULL;
    END CATCH;
END;
