-- 在 SSMS 选定独立 v3 测试库或整合测试库；本脚本不切换数据库。
-- 先执行 01、02、06、03、04、05。整合库可以跳过 03，仍可运行部署验收。
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
IF @@TRANCOUNT <> 0 THROW 51400, N'请在没有未提交事务的窗口运行测试。', 1;

DECLARE @columns TABLE (table_name SYSNAME, expected_count INT);
INSERT @columns VALUES (N'service_item', 9), (N'service_order', 15), (N'dispatch_record', 10);
IF EXISTS (SELECT 1 FROM @columns AS t WHERE t.expected_count <>
           (SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.' + t.table_name, N'U')))
    THROW 51401, N'三张表的列数应为 9、15、10。', 1;

DECLARE @fks TABLE (child_table SYSNAME, child_col SYSNAME, parent_table SYSNAME, parent_col SYSNAME);
INSERT @fks VALUES
    (N'service_order', N'elder_id', N'elder_profile', N'elder_id'),
    (N'service_order', N'service_id', N'service_item', N'service_id'),
    (N'dispatch_record', N'order_id', N'service_order', N'order_id'),
    (N'dispatch_record', N'caregiver_id', N'caregiver', N'caregiver_id'),
    (N'dispatch_record', N'schedule_id', N'caregiver_schedule', N'schedule_id'),
    (N'caregiver_certificate', N'service_id', N'service_item', N'service_id'),
    (N'work_record', N'dispatch_id', N'dispatch_record', N'dispatch_id');
IF EXISTS (
    SELECT 1 FROM @fks AS l
    WHERE NOT EXISTS (
        SELECT 1 FROM sys.foreign_keys AS f JOIN sys.foreign_key_columns AS k ON k.constraint_object_id = f.object_id
        WHERE f.parent_object_id = OBJECT_ID(N'dbo.' + l.child_table)
          AND f.referenced_object_id = OBJECT_ID(N'dbo.' + l.parent_table)
          AND COL_NAME(f.parent_object_id, k.parent_column_id) = l.child_col
          AND COL_NAME(f.referenced_object_id, k.referenced_column_id) = l.parent_col
          AND f.is_disabled = 0 AND f.is_not_trusted = 0 AND f.is_not_for_replication = 0
          AND f.delete_referential_action = 0 AND f.update_referential_action = 0
          AND NOT EXISTS (SELECT 1 FROM sys.foreign_key_columns AS x
                          WHERE x.constraint_object_id = f.object_id AND x.constraint_column_id > 1)
    )
) THROW 51402, N'至少一条成员2相关外键缺失、未启用、未受信任或使用级联。', 1;

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.dispatch_record') AND name = N'UX_M2_dispatch_active_order'
        AND is_unique = 1 AND has_filter = 1 AND is_disabled = 0
) THROW 51403, N'缺少有效派单筛选唯一索引。', 1;

IF OBJECT_ID(N'dbo.usp_M2_CreateOrder', N'P') IS NULL
    OR OBJECT_ID(N'dbo.usp_M2_OrderAction', N'P') IS NULL OR OBJECT_ID(N'dbo.usp_M2_CheckFence', N'P') IS NULL
    OR OBJECT_ID(N'dbo.vw_M2_OrderDetails', N'V') IS NULL
    OR OBJECT_ID(N'dbo.vw_M2_ActiveDispatch', N'V') IS NULL
    OR OBJECT_ID(N'dbo.vw_M2_ServiceSummary', N'V') IS NULL
    THROW 51404, N'缺少视图或存储过程。', 1;

IF EXISTS (SELECT order_id FROM dbo.dispatch_record WHERE dispatch_status IN (N'待接单', N'已接单')
           GROUP BY order_id HAVING COUNT(*) > 1)
    THROW 51405, N'已有订单存在多条有效派单。', 1;

DECLARE @standalone BIT = IIF(EXISTS (SELECT 1 FROM sys.extended_properties
    WHERE class = 0 AND name = N'M2_fixture_v3'), 1, 0);
DECLARE @items INT, @orders INT, @dispatches INT;
SELECT @items = COUNT(*) FROM dbo.service_item WHERE description LIKE N'M2:v1:item:[0-9][0-9]';
SELECT @orders = COUNT(*) FROM dbo.service_order WHERE remark LIKE N'M2:v1:order:[0-9][0-9]';
SELECT @dispatches = COUNT(*) FROM dbo.dispatch_record WHERE remark LIKE N'M2:v1:dispatch:[0-9][0-9]';
IF (@standalone = 1 OR @items + @orders + @dispatches > 0)
    AND (@items <> 20 OR @orders <> 20 OR @dispatches <> 20)
    THROW 51406, N'样例标识应分别匹配 20 条服务项目、订单和派单。', 1;

SELECT @items AS sample_services, @orders AS sample_orders, @dispatches AS sample_dispatches;
SELECT N'PASS 部署验收' AS result,
    (SELECT COUNT_BIG(*) FROM dbo.vw_M2_OrderDetails) AS order_view_rows,
    (SELECT COUNT_BIG(*) FROM dbo.vw_M2_ActiveDispatch) AS dispatch_view_rows,
    (SELECT COUNT_BIG(*) FROM dbo.vw_M2_ServiceSummary) AS summary_view_rows;

IF @standalone = 0
BEGIN
    PRINT N'整合库已完成部署验收。下面的故障注入用例只在独立测试库执行。';
    RETURN;
END;

DECLARE @tests TABLE (case_id INT PRIMARY KEY, name NVARCHAR(80), expected_error INT);
INSERT @tests VALUES
    (1,N'快照、改派、围栏、接单至完成、班次首尾相邻',0),
    (2,N'社区精确匹配',51110),
    (3,N'证书有效期',51111),
    (4,N'有效派单服务区间冲突',51113),
    (5,N'已完成服务仍占用班次累计容量',51114),
    (6,N'部分填写围栏字段',547),
    (7,N'老人跨模块外键',547),
    (8,N'直接插入第二条有效派单',2601),
    (9,N'改派失败恢复原派单',51110),
    (10,N'未签到禁止开始服务',51117),
    (11,N'预约必须完整落在开放班次',51112),
    (12,N'撤派和取消不得用于服务中订单',51107),
    (13,N'整改限制接单',51121),
    (14,N'未确认不得完成订单',51122),
    (15,N'再次派单必须填写改派原因',51119),
    (16,N'订单地址必须属于老人所在社区',51118),
    (17,N'缺少服务记录不得完成订单',51123);

DECLARE @results TABLE (case_id INT, test_name NVARCHAR(80), result VARCHAR(4));
DECLARE @case_id INT = 1, @caught INT, @message NVARCHAR(2048),
        @elder_id INT, @service_id INT, @caregiver_id INT, @alternate_id INT,
        @schedule_id INT, @alternate_schedule INT, @order_id INT, @second_order INT,
        @dispatch_id INT, @second_dispatch INT, @old_dispatch INT, @persistent_order INT,
        @start DATETIME2(0), @adjacent DATETIME2(0), @shift_end DATETIME2(0),
        @from DATE, @to DATE, @fence NVARCHAR(10), @distance FLOAT, @minutes INT,
        @capacity INT, @region NVARCHAR(200), @day_difference INT, @absent_elder INT = -2147483648;

SELECT @elder_id = elder_id FROM dbo.elder_profile WHERE elder_name = N'M2测试老人';
SELECT @service_id = service_id FROM dbo.service_item WHERE description = N'M2:v1:item:01';
SELECT @minutes = duration FROM dbo.service_item WHERE service_id = @service_id;
SELECT @persistent_order = order_id FROM dbo.service_order WHERE remark = N'M2:v1:order:19';
SELECT @old_dispatch = dispatch_id FROM dbo.dispatch_record
WHERE order_id = @persistent_order AND dispatch_status = N'待接单';

WHILE @case_id <= 17
BEGIN
    SET @caught = 0;
    SET @dispatch_id = NULL;
    SET @second_dispatch = NULL;
    SET @message = NULL;
    SET @start = DATEADD(DAY, 2, SYSDATETIME());
    SET @adjacent = DATEADD(MINUTE, @minutes, @start);
    SET @shift_end = DATEADD(HOUR, 8, @start);
    SET @from = CONVERT(DATE, @start);
    SET @to = @from;
    SET @day_difference = IIF(@case_id = 3, -1, 1);
    SET @to = DATEADD(DAY, @day_difference, @to);
    SET @from = DATEADD(DAY, -1, @from);
    SET @capacity = IIF(@case_id = 5, 1, 4);
    SET @region = IIF(@case_id = 2, N'清华园社区 ', N'清华园社区');

    BEGIN TRY
        BEGIN TRAN;
        INSERT dbo.caregiver (caregiver_name, service_area, employment_status)
            VALUES (N'M2过程测试护工', @region, N'在岗');
        SET @caregiver_id = CONVERT(INT, SCOPE_IDENTITY());
        INSERT dbo.caregiver (caregiver_name, service_area, employment_status)
            VALUES (N'M2过程测试改派护工', IIF(@case_id = 9, N'另一社区', N'清华园社区'), N'在岗');
        SET @alternate_id = CONVERT(INT, SCOPE_IDENTITY());
        INSERT dbo.caregiver_certificate
            (caregiver_id, certificate_no, service_id, qualification_level, valid_from, valid_to, certificate_status)
        VALUES (@caregiver_id, N'M2-ASSERT-A', @service_id, N'测试', @from, @to, N'有效'),
               (@alternate_id, N'M2-ASSERT-B', @service_id, N'测试', @from, @to, N'有效');
        INSERT dbo.caregiver_schedule (caregiver_id, start_time, end_time, max_orders, schedule_status)
        VALUES (@caregiver_id, @start, @shift_end, @capacity, IIF(@case_id = 11, N'关闭', N'开放'));
        SET @schedule_id = CONVERT(INT, SCOPE_IDENTITY());
        INSERT dbo.caregiver_schedule (caregiver_id, start_time, end_time, max_orders, schedule_status)
        VALUES (@alternate_id, @start, @shift_end, @capacity, N'开放');
        SET @alternate_schedule = CONVERT(INT, SCOPE_IDENTITY());
        IF @case_id = 13 INSERT dbo.rectification(caregiver_id, restrict_flag) VALUES (@caregiver_id, 1);

        IF @case_id = 6
        BEGIN
            EXEC dbo.usp_M2_CreateOrder @elder_id, @service_id, @start, N'清华园社区-测试',
                @order_id OUTPUT, @Latitude = 39.99;
        END
        ELSE IF @case_id = 7
        BEGIN
            IF EXISTS (SELECT 1 FROM dbo.elder_profile WHERE elder_id = @absent_elder)
                THROW 51407, N'测试哨兵 ID 已存在，无法验证外键拒绝。', 1;
            EXEC dbo.usp_M2_CreateOrder @absent_elder, @service_id, @start, N'清华园社区-测试', @order_id OUTPUT;
        END
        ELSE IF @case_id = 9
        BEGIN
            IF @old_dispatch IS NULL THROW 51408, N'缺少改派失败用例的原始待接单样例。', 1;
            SET @dispatch_id = @old_dispatch;
            EXEC dbo.usp_M2_OrderAction @persistent_order, 'REASSIGN', @alternate_id, @dispatch_id OUTPUT, @Reason = N'测试改派';
        END
        ELSE IF @case_id = 16
            EXEC dbo.usp_M2_CreateOrder @elder_id, @service_id, @start, N'其他社区-测试', @order_id OUTPUT;
        ELSE
        BEGIN
            EXEC dbo.usp_M2_CreateOrder @elder_id, @service_id, @start, N'清华园社区-测试',
                @order_id OUTPUT, @Latitude = 39.99, @Longitude = 116.33, @RadiusM = 100;
            EXEC dbo.usp_M2_OrderAction @order_id, 'DISPATCH', @caregiver_id, @dispatch_id OUTPUT;

            IF @case_id = 8
                INSERT dbo.dispatch_record (order_id, caregiver_id, schedule_id) VALUES (@order_id, @caregiver_id, @schedule_id);

            IF @case_id = 15
                EXEC dbo.usp_M2_OrderAction @order_id, 'REASSIGN', @alternate_id, @dispatch_id OUTPUT;

            IF @case_id = 1
            BEGIN
                UPDATE dbo.service_item SET duration = @minutes + 1, price = price + 1 WHERE service_id = @service_id;
                IF NOT EXISTS (
                    SELECT 1 FROM dbo.service_order AS o JOIN dbo.service_item AS s ON s.service_id = o.service_id
                    WHERE o.order_id = @order_id AND o.duration_minutes = @minutes AND o.total_amount = s.price - 1
                ) THROW 51409, N'项目变更后订单快照不正确。', 1;
                UPDATE dbo.service_item SET duration = @minutes, price = price - 1 WHERE service_id = @service_id;
                SET @second_dispatch = @dispatch_id;
                EXEC dbo.usp_M2_OrderAction @order_id, 'REASSIGN', @alternate_id, @dispatch_id OUTPUT, @Reason = N'护工调班';
                IF @second_dispatch = @dispatch_id OR NOT EXISTS (
                    SELECT 1 FROM dbo.dispatch_record WHERE dispatch_id = @second_dispatch AND dispatch_status = N'已撤回'
                ) THROW 51410, N'改派没有保留已撤回的旧派单。', 1;
                SET @second_dispatch = NULL;
                SET @schedule_id = @alternate_schedule;
                SET @caregiver_id = @alternate_id;

                EXEC dbo.usp_M2_CheckFence @order_id, N'39.9900000,116.3300000', @fence OUTPUT, @distance OUTPUT;
                IF @fence <> N'通过' OR @distance IS NULL OR @distance <> 0
                    THROW 51411, N'围栏同点测试失败。', 1;
                EXEC dbo.usp_M2_CheckFence @order_id, N'40.9900000,116.3300000', @fence OUTPUT, @distance OUTPUT;
                IF @fence <> N'未通过' OR @distance IS NULL OR @distance <= 100
                    THROW 51412, N'围栏超半径测试失败。', 1;
                EXEC dbo.usp_M2_CheckFence @order_id, N'39.9900000，116.3300000', @fence OUTPUT, @distance OUTPUT;
                IF @fence <> N'待校验' OR @distance IS NOT NULL
                    THROW 51413, N'非法分隔符必须转人工校验。', 1;
                EXEC dbo.usp_M2_CheckFence @order_id, N'91,116.33', @fence OUTPUT, @distance OUTPUT;
                IF @fence <> N'待校验' OR @distance IS NOT NULL
                    THROW 51413, N'越界坐标必须转人工校验。', 1;
            END;

            IF @case_id IN (1, 5, 10, 12, 14, 17)
            BEGIN
                EXEC dbo.usp_M2_OrderAction @order_id, 'ACCEPT', @DispatchID = @dispatch_id OUTPUT;
                IF @case_id <> 10
                    INSERT dbo.work_record
                        (schedule_id, dispatch_id, check_in_time, check_in_location, fence_result, review_status)
                    VALUES (@schedule_id, @dispatch_id, @start, N'39.99,116.33', N'通过', N'待审核');
                EXEC dbo.usp_M2_OrderAction @order_id, 'START', @DispatchID = @dispatch_id OUTPUT;
                IF @case_id = 12
                    EXEC dbo.usp_M2_OrderAction @order_id, 'CANCEL', @DispatchID = @dispatch_id OUTPUT;
                UPDATE dbo.work_record
                SET check_out_time = @adjacent, check_out_location = N'39.99,116.33',
                    effective_minutes = @minutes, review_status = N'通过'
                WHERE dispatch_id = @dispatch_id;
                IF @case_id = 14
                    EXEC dbo.usp_M2_OrderAction @order_id, 'COMPLETE', @DispatchID = @dispatch_id OUTPUT, @ServiceRecord = N'完成上门服务';
                ELSE IF @case_id = 17
                    EXEC dbo.usp_M2_OrderAction @order_id, 'COMPLETE', @DispatchID = @dispatch_id OUTPUT, @Confirmed = 1;
                ELSE
                    EXEC dbo.usp_M2_OrderAction @order_id, 'COMPLETE', @DispatchID = @dispatch_id OUTPUT, @Confirmed = 1, @ServiceRecord = N'完成上门服务';
                IF NOT EXISTS (SELECT 1 FROM dbo.service_order WHERE order_id = @order_id AND order_status = N'已完成' AND confirm_status = N'已确认')
                    THROW 51414, N'完成服务后的订单状态错误。', 1;
            END;

            IF @case_id IN (1, 4, 5)
            BEGIN
                IF @case_id = 4 SET @adjacent = DATEADD(MINUTE, 1, @start);
                EXEC dbo.usp_M2_CreateOrder @elder_id, @service_id, @adjacent, N'清华园社区-相邻时段', @second_order OUTPUT;
                EXEC dbo.usp_M2_OrderAction @second_order, 'DISPATCH', @caregiver_id, @second_dispatch OUTPUT;
            END;
            IF @case_id = 1
            BEGIN
                EXEC dbo.usp_M2_OrderAction @second_order, 'REJECT', @DispatchID = @second_dispatch OUTPUT;
                IF NOT EXISTS (SELECT 1 FROM dbo.service_order WHERE order_id = @second_order AND order_status = N'待派单')
                    THROW 51415, N'拒单后订单未回到待派单。', 1;
                EXEC dbo.usp_M2_OrderAction @second_order, 'DISPATCH', @caregiver_id, @second_dispatch OUTPUT, @Reason = N'拒单后重新派单';
                EXEC dbo.usp_M2_OrderAction @second_order, 'CANCEL', @DispatchID = @second_dispatch OUTPUT;
                IF NOT EXISTS (
                    SELECT 1 FROM dbo.service_order AS o JOIN dbo.dispatch_record AS d ON d.order_id = o.order_id
                    WHERE o.order_id = @second_order AND o.order_status = N'已取消'
                        AND d.dispatch_id = @second_dispatch AND d.dispatch_status = N'已撤回'
                ) THROW 51416, N'取消订单未同步撤回派单。', 1;
            END;
        END;
        ROLLBACK;
    END TRY
    BEGIN CATCH
        SELECT @caught = ERROR_NUMBER(), @message = ERROR_MESSAGE();
        IF XACT_STATE() <> 0 ROLLBACK;
    END CATCH;

    IF NOT EXISTS (SELECT 1 FROM @tests WHERE case_id = @case_id AND expected_error = @caught)
    BEGIN
        SET @message = CONCAT(N'用例 ', @case_id, N' 失败。实际错误号 ', @caught, N'。', @message);
        THROW 51420, @message, 1;
    END;
    IF @case_id = 9 AND NOT EXISTS (
        SELECT 1 FROM dbo.dispatch_record AS d JOIN dbo.service_order AS o ON o.order_id = d.order_id
        WHERE d.dispatch_id = @old_dispatch AND d.dispatch_status = N'待接单' AND o.order_status = N'待接单'
    ) THROW 51421, N'失败的改派没有恢复原派单与订单状态。', 1;

    INSERT @results SELECT case_id, name, 'PASS' FROM @tests WHERE case_id = @case_id;
    SET @case_id += 1;
END;
SELECT case_id, test_name, result FROM @results ORDER BY case_id;
PRINT N'PASS 17 项独立业务及约束用例。测试写入已回滚，IDENTITY 编号可能出现空号。';
