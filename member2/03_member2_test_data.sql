-- 仅用于测试库。独立路径自动使用模拟父表，整合路径请填写真实且已核对的 ID。
DECLARE @AllowIntegrationSeed BIT = 0,
        @ElderID INT = NULL, @CaregiverID INT = NULL, @ServiceID INT = NULL,
        @AppointmentTime DATETIME2(0) = NULL;  -- 整合路径：预约时间必须在未来且落在开放班次。

SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @standalone BIT = IIF(EXISTS (SELECT 1 FROM sys.extended_properties
    WHERE class = 0 AND name = N'M2_fixture_v1'), 1, 0);

IF @standalone = 0 AND
    (ISNULL(@AllowIntegrationSeed, 0) <> 1 OR @ElderID IS NULL OR @CaregiverID IS NULL
     OR @ServiceID IS NULL OR @AppointmentTime IS NULL)
    THROW 51200, N'整合测试请显式启用种子，并填写测试老人、护工、项目的实际 ID 及预约时间。', 1;
IF OBJECT_ID(N'dbo.usp_M2_OrderAction', N'P') IS NULL
    THROW 51201, N'请先执行 01、02、06，再运行本文件。', 1;

BEGIN TRY
    BEGIN TRAN;
    DECLARE @lock_result INT;
    EXEC @lock_result = sys.sp_getapplock @Resource = N'M2.OrderAction.v1', @LockMode = N'Exclusive',
                                         @LockOwner = N'Transaction', @LockTimeout = 10000;
    IF @lock_result < 0 THROW 51102, N'测试数据事务锁获取失败，请重试。', 1;

    DECLARE @items TABLE (seq INT PRIMARY KEY, service_name NVARCHAR(50), service_type NVARCHAR(30),
                          price DECIMAL(10,2), duration INT);
    INSERT @items VALUES
        (1,N'上门保洁',N'生活照料',80,30), (2,N'陪同就医',N'医疗陪护',150,180),
        (3,N'上门做饭',N'生活照料',60,60), (4,N'助浴服务',N'生活照料',100,90),
        (5,N'陪伴聊天',N'精神慰藉',40,60), (6,N'生活采购',N'生活照料',45,60),
        (7,N'助行陪伴',N'生活照料',55,60), (8,N'家电清洁',N'家政服务',90,120),
        (9,N'居家整理',N'家政服务',70,90), (10,N'代取药品',N'医疗陪护',35,45),
        (11,N'康复陪练',N'健康支持',120,90), (12,N'读书陪伴',N'精神慰藉',35,60),
        (13,N'预约挂号协助',N'医疗陪护',30,30), (14,N'衣物洗护',N'生活照料',65,90),
        (15,N'陪同散步',N'精神慰藉',45,60), (16,N'上门理发',N'生活照料',50,45),
        (17,N'厨房整理',N'家政服务',60,60), (18,N'节日慰问',N'精神慰藉',40,45),
        (19,N'送餐上门',N'生活照料',25,30), (20,N'旧物收纳',N'家政服务',75,90);

    INSERT dbo.service_item (service_name, service_type, price, duration, description, status)
    SELECT N'M2测试-' + i.service_name, i.service_type, i.price, i.duration,
           CONCAT(N'M2:v1:item:', RIGHT('00' + CONVERT(VARCHAR(2), i.seq), 2)),
           IIF(i.seq = 20, N'下架', N'上架')
    FROM @items AS i
    WHERE NOT EXISTS (SELECT 1 FROM dbo.service_item AS s WITH (UPDLOCK, HOLDLOCK)
        WHERE s.description = CONCAT(N'M2:v1:item:', RIGHT('00' + CONVERT(VARCHAR(2), i.seq), 2)));

    IF EXISTS (
        SELECT 1 FROM @items AS i
        WHERE (SELECT COUNT(*) FROM dbo.service_item AS s
            WHERE s.description = CONCAT(N'M2:v1:item:', RIGHT('00' + CONVERT(VARCHAR(2), i.seq), 2))) <> 1
    ) THROW 51202, N'已有重复的服务项目测试标识，请检查测试库。', 1;

    DECLARE @community NVARCHAR(200), @schedule_start DATETIME2(0);
    IF @standalone = 1
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.elder_profile WHERE elder_name = N'M2测试老人')
            INSERT dbo.elder_profile (elder_name) VALUES (N'M2测试老人');
        IF NOT EXISTS (SELECT 1 FROM dbo.caregiver WHERE caregiver_name = N'M2测试护工')
            INSERT dbo.caregiver (caregiver_name, service_area, employment_status)
                VALUES (N'M2测试护工', N'清华园社区', N'在岗');

        SELECT @ElderID = elder_id FROM dbo.elder_profile WHERE elder_name = N'M2测试老人';
        SELECT @CaregiverID = caregiver_id FROM dbo.caregiver WHERE caregiver_name = N'M2测试护工';
        SELECT @ServiceID = service_id FROM dbo.service_item WHERE description = N'M2:v1:item:01';

        SELECT @schedule_start = MIN(start_time) FROM dbo.caregiver_schedule WHERE caregiver_id = @CaregiverID;
        IF @schedule_start IS NULL
        BEGIN
            SET @schedule_start = DATEADD(HOUR, 8, CONVERT(DATETIME2(0), DATEADD(DAY, 1, CONVERT(DATE, SYSDATETIME()))));
            INSERT dbo.caregiver_schedule (caregiver_id, start_time, end_time, max_orders, schedule_status)
                VALUES (@CaregiverID, @schedule_start, DATEADD(HOUR, 16, @schedule_start), 20, N'开放');
        END;

        IF NOT EXISTS (SELECT 1 FROM dbo.caregiver_certificate
                       WHERE caregiver_id = @CaregiverID AND service_id = @ServiceID AND certificate_no = N'M2-DEMO')
            INSERT dbo.caregiver_certificate
                (caregiver_id, certificate_no, service_id, qualification_level, valid_from, valid_to, certificate_status)
            VALUES (@CaregiverID, N'M2-DEMO', @ServiceID, N'演示', CONVERT(DATE, @schedule_start),
                    DATEADD(DAY, 1, CONVERT(DATE, @schedule_start)), N'有效');
    END;

    SELECT @community = service_area FROM dbo.caregiver WHERE caregiver_id = @CaregiverID;
    IF @community IS NULL OR CHARINDEX(N'-', @community) > 0 OR LEN(@community) > 188
        THROW 51203, N'护工不存在或服务区域不能用于生成测试地址。', 1;

    DECLARE @seq INT = 1, @order_id INT, @dispatch_id INT, @note NVARCHAR(255),
            @address NVARCHAR(200), @when DATETIME2(0), @action VARCHAR(12), @dispatch_note NVARCHAR(255);
    SET @address = @community + N'-演示上门地点';

    WHILE @seq <= 20
    BEGIN
        SET @note = CONCAT(N'M2:v1:order:', RIGHT('00' + CONVERT(VARCHAR(2), @seq), 2));
        SET @dispatch_note = CONCAT(N'M2:v1:dispatch:', RIGHT('00' + CONVERT(VARCHAR(2), @seq), 2));
        SET @order_id = NULL;
        IF (SELECT COUNT(*) FROM dbo.service_order WHERE remark = @note) > 1
            THROW 51204, N'已有重复的订单测试标识，请检查测试库。', 1;
        SELECT @order_id = order_id FROM dbo.service_order WHERE remark = @note;

        IF @order_id IS NULL
        BEGIN
            SET @when = IIF(@standalone = 1, DATEADD(MINUTE, 45 * (@seq - 1), @schedule_start), @AppointmentTime);
            EXEC dbo.usp_M2_CreateOrder @ElderID = @ElderID, @ServiceID = @ServiceID,
                @AppointmentTime = @when, @ServiceAddress = @address, @OrderID = @order_id OUTPUT,
                @Latitude = 39.99, @Longitude = 116.33, @RadiusM = 100, @Remark = @note;
            EXEC dbo.usp_M2_OrderAction @OrderID = @order_id, @Action = 'DISPATCH',
                @CaregiverID = @CaregiverID, @DispatchID = @dispatch_id OUTPUT, @Reason = @dispatch_note;

            -- 整合样例复用一个空闲时段。每条测试派单最终都会撤回，下一条可复用其名额。
            SET @action = CASE WHEN @standalone = 0 THEN 'WITHDRAW'
                WHEN @seq < 17 THEN IIF(@seq % 2 = 0, 'REJECT', 'WITHDRAW')
                WHEN @seq IN (17, 18) THEN 'ACCEPT' WHEN @seq = 20 THEN 'CANCEL' END;
            IF @action IS NOT NULL
                EXEC dbo.usp_M2_OrderAction @OrderID = @order_id, @Action = @action, @DispatchID = @dispatch_id OUTPUT;
        END;

        IF (SELECT COUNT(*) FROM dbo.dispatch_record WHERE order_id = @order_id AND remark = @dispatch_note) <> 1
            THROW 51205, N'订单对应的派单测试标识缺失或重复，请检查测试库。', 1;
        SET @seq += 1;
    END;
    COMMIT;
    SELECT 20 AS sample_services, 20 AS sample_orders, 20 AS sample_dispatches;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    THROW;
END CATCH;
