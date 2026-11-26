-- =============================================================
-- 成员5 补贴核算与质量监管  |  07 结构验收与业务测试
-- 前置：01 → 02 → 06 → 03 → 04 → 05 均已执行，且成员1/2/3 的
--       父表与测试数据已导入（elder_profile / service_org /
--       service_item / service_order / caregiver / work_record）。
-- 说明：业务测试全部在事务内执行并回滚，不污染联调库。
--       末尾输出逐项 PASS / FAIL 与汇总计数。
-- =============================================================
SET NOCOUNT ON;
SET XACT_ABORT OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;

IF @@TRANCOUNT <> 0
    THROW 52300, N'请在没有未提交事务的查询窗口运行本脚本。', 1;

-- =============================================================
-- A. 结构验收
-- =============================================================
DECLARE @cols TABLE (table_name SYSNAME, expected INT);
INSERT @cols VALUES
    (N'subsidy_policy', 17),
    (N'subsidy_application', 18),
    (N'subsidy_application_item', 10),
    (N'subsidy_audit_log', 12),
    (N'quality_inspection', 18),
    (N'rectification', 16);

IF EXISTS (
    SELECT 1 FROM @cols AS c
    WHERE OBJECT_ID(N'dbo.' + c.table_name, N'U') IS NULL)
    THROW 52301, N'6 张业务表未建全，请先执行 01_member5_tables.sql。', 1;

IF EXISTS (
    SELECT 1 FROM @cols AS c
    WHERE c.expected <> (SELECT COUNT(*) FROM sys.columns
                         WHERE object_id = OBJECT_ID(N'dbo.' + c.table_name, N'U')))
BEGIN
    DECLARE @bad NVARCHAR(400) = N'';
    SELECT @bad = @bad + N'  ' + c.table_name + N' 实际 ' +
           CAST((SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.' + c.table_name, N'U')) AS NVARCHAR(10)) +
           N' 列，应为 ' + CAST(c.expected AS NVARCHAR(10)) + CHAR(13) + CHAR(10)
    FROM @cols AS c
    WHERE c.expected <> (SELECT COUNT(*) FROM sys.columns
                         WHERE object_id = OBJECT_ID(N'dbo.' + c.table_name, N'U'));
    THROW 52302, @bad, 1;
END;

-- 主键
IF EXISTS (
    SELECT 1 FROM @cols AS c
    WHERE NOT EXISTS (SELECT 1 FROM sys.indexes
                      WHERE object_id = OBJECT_ID(N'dbo.' + c.table_name, N'U')
                        AND is_primary_key = 1))
    THROW 52303, N'存在缺少主键的业务表。', 1;

-- 本模块内部外键
DECLARE @fks TABLE (child_table SYSNAME, child_col SYSNAME, parent_table SYSNAME, parent_col SYSNAME);
INSERT @fks VALUES
    (N'subsidy_application',      N'policy_id',       N'subsidy_policy',          N'policy_id'),
    (N'subsidy_application_item', N'application_id',  N'subsidy_application',     N'application_id'),
    (N'subsidy_audit_log',        N'application_id',  N'subsidy_application',     N'application_id'),
    (N'rectification',            N'inspection_id',   N'quality_inspection',      N'inspection_id');

IF EXISTS (
    SELECT 1 FROM @fks AS l
    WHERE NOT EXISTS (
        SELECT 1 FROM sys.foreign_keys AS f
        JOIN sys.foreign_key_columns AS k ON k.constraint_object_id = f.object_id
        WHERE f.parent_object_id = OBJECT_ID(N'dbo.' + l.child_table)
          AND f.referenced_object_id = OBJECT_ID(N'dbo.' + l.parent_table)
          AND COL_NAME(f.parent_object_id, k.parent_column_id) = l.child_col
          AND COL_NAME(f.referenced_object_id, k.referenced_column_id) = l.parent_col
          AND f.is_disabled = 0 AND f.is_not_trusted = 0
          AND f.delete_referential_action = 0 AND f.update_referential_action = 0))
    THROW 52304, N'本模块内部外键缺失、未启用或使用了级联删除。', 1;

-- 跨模块外键：父表就绪者必须存在；成员4 sys_user 已交付，4 条用户外键一并核对
DECLARE @x TABLE (child_table SYSNAME, child_col SYSNAME, parent_table SYSNAME, parent_col SYSNAME);
INSERT @x VALUES
    (N'subsidy_policy',          N'service_item_id', N'service_item',  N'service_id'),
    (N'subsidy_application',     N'elder_id',        N'elder_profile', N'elder_id'),
    (N'subsidy_application_item',N'order_id',        N'service_order', N'order_id'),
    (N'quality_inspection',      N'order_id',        N'service_order', N'order_id'),
    (N'quality_inspection',      N'caregiver_id',    N'caregiver',     N'caregiver_id'),
    (N'rectification',           N'caregiver_id',    N'caregiver',     N'caregiver_id'),
    (N'rectification',           N'org_id',          N'service_org',   N'org_id'),
    (N'subsidy_application',     N'current_auditor_id', N'sys_user',   N'user_id'),
    (N'subsidy_audit_log',       N'auditor_id',      N'sys_user',      N'user_id'),
    (N'quality_inspection',      N'inspector_id',    N'sys_user',      N'user_id'),
    (N'rectification',           N'reviewer_id',     N'sys_user',      N'user_id');

DECLARE @miss NVARCHAR(MAX) = N'';
SELECT @miss = @miss + N'  ' + l.child_table + N'.' + l.child_col + N' → ' +
               l.parent_table + N'(' + l.parent_col + N')' + CHAR(13) + CHAR(10)
FROM @x AS l
WHERE OBJECT_ID(N'dbo.' + l.parent_table, N'U') IS NOT NULL
  AND NOT EXISTS (
        SELECT 1 FROM sys.foreign_keys AS f
        JOIN sys.foreign_key_columns AS k ON k.constraint_object_id = f.object_id
        WHERE f.parent_object_id = OBJECT_ID(N'dbo.' + l.child_table)
          AND f.referenced_object_id = OBJECT_ID(N'dbo.' + l.parent_table)
          AND COL_NAME(f.parent_object_id, k.parent_column_id) = l.child_col);

IF LEN(@miss) > 0
BEGIN
    PRINT N'【警告】以下跨模块外键尚未挂载（父表已存在，请重跑 02_member5_foreign_keys.sql）：';
    PRINT @miss;
END;

-- 视图 / 触发器 / 存储过程
IF OBJECT_ID(N'dbo.vw_M5_ApplicationProgress', N'V') IS NULL
   OR OBJECT_ID(N'dbo.vw_M5_SubsidyTrace', N'V') IS NULL
   OR OBJECT_ID(N'dbo.vw_M5_CaregiverBlocked', N'V') IS NULL
   OR OBJECT_ID(N'dbo.vw_M5_OrgBlocked', N'V') IS NULL
    THROW 52305, N'4 个视图未建全，请先执行 05_member5_views.sql。', 1;

IF OBJECT_ID(N'dbo.TR_M5_Item_Guard', N'TR') IS NULL
    THROW 52306, N'明细校验触发器 TR_M5_Item_Guard 不存在。', 1;
IF OBJECT_ID(N'dbo.TR_M5_Rect_SyncFlag', N'TR') IS NULL
    THROW 52306, N'整改同步触发器 TR_M5_Rect_SyncFlag 不存在。', 1;

IF OBJECT_ID(N'dbo.usp_M5_CreateApplication', N'P') IS NULL
   OR OBJECT_ID(N'dbo.usp_M5_RefreshTotals', N'P') IS NULL
   OR OBJECT_ID(N'dbo.usp_M5_SyncRestrictFlag', N'P') IS NULL
   OR OBJECT_ID(N'dbo.usp_M5_LockScope', N'P') IS NULL
   OR OBJECT_ID(N'dbo.usp_M5_CreateRectification', N'P') IS NULL
   OR OBJECT_ID(N'dbo.usp_M5_SubmitRectification', N'P') IS NULL
   OR OBJECT_ID(N'dbo.usp_M5_ReviewRectification', N'P') IS NULL
   OR OBJECT_ID(N'dbo.usp_M5_AssignAuditor', N'P') IS NULL
   OR OBJECT_ID(N'dbo.usp_M5_AuditAdvance', N'P') IS NULL
    THROW 52307, N'9 个存储过程未建全，请先执行 06_member5_procedures.sql。', 1;

PRINT N'【PASS】结构验收：6 表 91 字段、主键、内部外键、4 视图、2 触发器、9 存储过程齐备。';
GO

-- =============================================================
-- B. 测试数据规模（每表 ≥ 20 条）
-- =============================================================
DECLARE @cnt TABLE (table_name SYSNAME, n INT);
INSERT @cnt
SELECT N'subsidy_policy',          COUNT(*) FROM dbo.subsidy_policy
UNION ALL SELECT N'subsidy_application',      COUNT(*) FROM dbo.subsidy_application
UNION ALL SELECT N'subsidy_application_item', COUNT(*) FROM dbo.subsidy_application_item
UNION ALL SELECT N'subsidy_audit_log',        COUNT(*) FROM dbo.subsidy_audit_log
UNION ALL SELECT N'quality_inspection',       COUNT(*) FROM dbo.quality_inspection
UNION ALL SELECT N'rectification',            COUNT(*) FROM dbo.rectification;

SELECT table_name AS 表名, n AS 记录数,
       CASE WHEN n >= 20 THEN N'PASS' ELSE N'FAIL' END AS 结果
FROM @cnt ORDER BY table_name;

IF EXISTS (SELECT 1 FROM @cnt WHERE n < 20)
BEGIN
    PRINT N'【警告】有表不足 20 条记录，请执行 03_member5_test_data.sql（需先导入成员1/2 数据）。';
END;
GO

-- =============================================================
-- C. 业务规则测试（事务内执行，结束回滚）
-- =============================================================
IF OBJECT_ID(N'tempdb..#res') IS NOT NULL DROP TABLE #res;
CREATE TABLE #res (seq INT IDENTITY, case_name NVARCHAR(60), result NVARCHAR(6), detail NVARCHAR(200));

DECLARE @app_id INT, @elder_id INT, @policy_id INT, @cycle CHAR(7),
        @order_id INT, @caregiver_id INT, @service_amount DECIMAL(10,2),
        @insp_id INT, @rectify_id INT, @msg NVARCHAR(400);

SELECT TOP 1 @app_id = application_id, @elder_id = elder_id, @policy_id = policy_id, @cycle = settle_cycle
FROM dbo.subsidy_application ORDER BY application_id DESC;

-- 选一个尚未被任何明细占用的订单，避免撞上 UQ_M5_item_order
SELECT TOP 1 @order_id = o.order_id
FROM dbo.service_order AS o
WHERE NOT EXISTS (SELECT 1 FROM dbo.subsidy_application_item AS i WHERE i.order_id = o.order_id)
ORDER BY o.order_id DESC;
-- 成员3 的护工表若尚未合并，相关用例自动 SKIP，不影响其余测试
IF OBJECT_ID(N'dbo.caregiver', N'U') IS NOT NULL
    SELECT TOP 1 @caregiver_id = caregiver_id FROM dbo.caregiver ORDER BY caregiver_id DESC;
SET @service_amount = 100.00;

-- T1 同一老人·同一政策·同一周期 唯一约束拦截重复申报
IF @app_id IS NULL
    INSERT #res (case_name, result, detail) VALUES (N'T1 重复申报拦截', N'SKIP', N'无申报数据，跳过');
ELSE
BEGIN
    DECLARE @ok1 BIT = 0;
    BEGIN TRY
        BEGIN TRAN;
        INSERT dbo.subsidy_application
            (elder_id, policy_id, settle_cycle, application_amount, self_pay_amount,
             order_count, total_hours, apply_type, audit_status, create_by)
        VALUES (@elder_id, @policy_id, @cycle, 0, 0, 0, 0, N'系统汇总', N'待社区初审', N'验收脚本');
        ROLLBACK;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) SET @ok1 = 1;
        SET @msg = ERROR_MESSAGE();
    END CATCH;
    INSERT #res (case_name, result, detail)
    VALUES (N'T1 重复申报拦截', CASE WHEN @ok1 = 1 THEN N'PASS' ELSE N'FAIL' END,
            CASE WHEN @ok1 = 1 THEN N'唯一约束 UQ_M5_app_once 生效' ELSE N'重复行被写入' END);
END

-- T2 金额勾稽：补贴 + 自付 超过服务金额应被拒绝（CHECK CK_M5_item_reconcile 先于 AFTER 触发器求值）
IF @app_id IS NULL OR @order_id IS NULL
    INSERT #res (case_name, result, detail) VALUES (N'T2 金额勾稽拦截', N'SKIP', N'缺申报单或订单，跳过');
ELSE
BEGIN
    DECLARE @ok2 BIT = 0, @why2 NVARCHAR(140) = N'';
    BEGIN TRY
        BEGIN TRAN;
        INSERT dbo.subsidy_application_item
            (application_id, order_id, work_id, service_amount, subsidy_amount, self_pay_amount, valid_hours, verify_result)
        VALUES (@app_id, @order_id, NULL, @service_amount, @service_amount, @service_amount, 0, N'通过');
        ROLLBACK;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        -- CHECK 约束在 AFTER 触发器之前求值，两条路径都说明规则已生效
        IF ERROR_NUMBER() = 52100
        BEGIN
            SET @ok2 = 1;
            SET @why2 = N'触发器 TR_M5_Item_Guard 拦截（52100）';
        END
        ELSE IF ERROR_NUMBER() = 547 AND ERROR_MESSAGE() LIKE N'%CK_M5_item_reconcile%'
        BEGIN
            SET @ok2 = 1;
            SET @why2 = N'CHECK 约束 CK_M5_item_reconcile 拦截（547，先于触发器求值）';
        END
        ELSE
            SET @why2 = N'未被拦截：' + LEFT(ERROR_MESSAGE(), 100);
    END CATCH;
    INSERT #res (case_name, result, detail)
    VALUES (N'T2 金额勾稽拦截', CASE WHEN @ok2 = 1 THEN N'PASS' ELSE N'FAIL' END,
            CASE WHEN @ok2 = 1 THEN @why2 ELSE ISNULL(NULLIF(@why2, N''), N'越界金额被接受') END);
END

-- T3 缺有效工时的明细被自动标记为「工时缺失」
IF @app_id IS NULL OR @order_id IS NULL
    INSERT #res (case_name, result, detail) VALUES (N'T3 工时缺失标记', N'SKIP', N'缺申报单或订单，跳过');
ELSE
BEGIN
    DECLARE @ok3 BIT = 0, @flag NVARCHAR(12);
    BEGIN TRY
        BEGIN TRAN;
        INSERT dbo.subsidy_application_item
            (application_id, order_id, work_id, service_amount, subsidy_amount, self_pay_amount, valid_hours, verify_result)
        VALUES (@app_id, @order_id, NULL, @service_amount, 40, 60, NULL, N'通过');
        DECLARE @new_item INT = SCOPE_IDENTITY();
        SELECT @flag = verify_result FROM dbo.subsidy_application_item WHERE item_id = @new_item;
        IF @flag = N'工时缺失' SET @ok3 = 1;
        ROLLBACK;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
    END CATCH;
    INSERT #res (case_name, result, detail)
    VALUES (N'T3 工时缺失标记', CASE WHEN @ok3 = 1 THEN N'PASS' ELSE N'FAIL' END,
            CASE WHEN @ok3 = 1 THEN N'无工时明细 verify_result 已置为「工时缺失」' ELSE N'未被标记' END);
END

-- T4 抽查对象互斥：订单与护工同时为空应被 CHECK 拒绝
DECLARE @ok4 BIT = 0, @t4_user INT = NULL;
IF OBJECT_ID(N'dbo.sys_user', N'U') IS NOT NULL
    SELECT @t4_user = MIN(user_id) FROM dbo.sys_user;

IF @t4_user IS NULL
BEGIN
    INSERT #res (case_name, result, detail)
    VALUES (N'T4 抽查对象互斥', N'SKIP', N'sys_user 无可用账号，无法构造抽查行');
END
ELSE
BEGIN
    BEGIN TRY
        BEGIN TRAN;
        INSERT dbo.quality_inspection
            (object_type, order_id, caregiver_id, inspect_method, inspect_source, inspect_time,
             inspector_id, inspector_org, score, authenticity, inspect_result, inspect_status)
        VALUES (N'订单', NULL, NULL, N'电话回访', N'专项整治', SYSDATETIME(),
                @t4_user, N'海淀区民政局', 90, N'真实', N'合格', N'已完成');
        ROLLBACK;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_MESSAGE() LIKE N'%CK_M5_insp_object_exclusive%' SET @ok4 = 1;
    END CATCH;
    INSERT #res (case_name, result, detail)
    VALUES (N'T4 抽查对象互斥', CASE WHEN @ok4 = 1 THEN N'PASS' ELSE N'FAIL' END,
            CASE WHEN @ok4 = 1 THEN N'对象互斥 CHECK 约束生效' ELSE N'对象全空的抽查被接受' END);
END

-- T5 整改复查通过 → restrict_flag 由触发器自动转 'N'（不手工赋值、不调用同步过程）
SELECT TOP 1 @rectify_id = rectify_id, @insp_id = inspection_id
FROM dbo.rectification
WHERE restrict_flag = 'Y' AND rectify_status <> N'复查通过'
ORDER BY rectify_id DESC;

IF @rectify_id IS NULL
    INSERT #res (case_name, result, detail) VALUES (N'T5 整改解除限制', N'SKIP', N'无处于限制中的整改记录，跳过');
ELSE
BEGIN
    DECLARE @ok5 BIT = 0, @flag5 CHAR(1), @rel5 DATETIME2(0);
    BEGIN TRY
        BEGIN TRAN;
        -- 只改状态与结论，restrict_flag 与 release_time 完全交给触发器
        UPDATE dbo.rectification
           SET rectify_status = N'复查通过',
               review_result  = N'通过',
               review_time    = SYSDATETIME()
         WHERE rectify_id = @rectify_id;
        SELECT @flag5 = restrict_flag, @rel5 = release_time
        FROM dbo.rectification WHERE rectify_id = @rectify_id;
        IF @flag5 = 'N' AND @rel5 IS NOT NULL SET @ok5 = 1;
        ROLLBACK;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
    END CATCH;
    INSERT #res (case_name, result, detail)
    VALUES (N'T5 整改解除限制', CASE WHEN @ok5 = 1 THEN N'PASS' ELSE N'FAIL' END,
            CASE WHEN @ok5 = 1 THEN N'触发器 TR_M5_Rect_SyncFlag 同步置 N 并写 release_time'
                 ELSE N'restrict_flag 或 release_time 未联动' END);
END

-- T6 限制接单视图可查询，且 block_level 取值合法、不返回空护工
DECLARE @ok6 BIT = 0, @bad6 INT = 0, @lv6 INT = 0;
BEGIN TRY
    SELECT @bad6 = COUNT(*) FROM dbo.vw_M5_CaregiverBlocked WHERE caregiver_id IS NULL;
    SELECT @lv6  = COUNT(*) FROM dbo.vw_M5_CaregiverBlocked
    WHERE block_level NOT IN (N'护工级', N'机构级', N'护工+机构');
    SET @ok6 = 1;
END TRY
BEGIN CATCH
    SET @ok6 = 0;
END CATCH;
INSERT #res (case_name, result, detail)
VALUES (N'T6 限制接单视图', CASE WHEN @ok6 = 1 AND @bad6 = 0 AND @lv6 = 0 THEN N'PASS' ELSE N'FAIL' END,
        CASE WHEN @ok6 = 1 AND @bad6 = 0 AND @lv6 = 0
             THEN N'vw_M5_CaregiverBlocked 可查询，block_level 合法且无空护工'
             ELSE N'视图不可用、block_level 异常或返回空护工' END);

-- T7 计价口径校验：按次项目配“按工时”、按小时项目配“按次定额”，应由存储过程拦截（52116）
DECLARE @ok7 BIT = 0, @cu7 NVARCHAR(10), @sid7 INT, @pid7 INT, @det7 NVARCHAR(200) = N'';
IF OBJECT_ID(N'dbo.service_item', N'U') IS NULL
   OR COL_LENGTH(N'dbo.service_item', N'charge_unit') IS NULL
BEGIN
    INSERT #res (case_name, result, detail)
    VALUES (N'T7 计价口径校验', N'SKIP', N'成员2 service_item 未建或缺 charge_unit 列，跳过');
END
ELSE
BEGIN
    SELECT TOP 1 @sid7 = service_id, @cu7 = charge_unit
    FROM dbo.service_item
    WHERE charge_unit IN (N'次', N'小时')
    ORDER BY service_id;

    IF @sid7 IS NULL
    BEGIN
        INSERT #res (case_name, result, detail)
        VALUES (N'T7 计价口径校验', N'SKIP', N'service_item 无 charge_unit 数据，跳过');
    END
    ELSE
    BEGIN
        BEGIN TRY
            BEGIN TRAN;
            -- 故意造一条与计价单位相矛盾的政策
            INSERT dbo.subsidy_policy
                (policy_name, district_code, target_category, service_item_id, subsidy_mode,
                 subsidy_standard, subsidy_ratio, settle_cycle, effective_date, expire_date,
                 doc_no, policy_status)
            VALUES
                (N'验收用计价口径政策', N'310101', N'普通', @sid7,
                 CASE WHEN @cu7 = N'次' THEN N'按工时' ELSE N'按次定额' END,
                 10.00, NULL, N'月', DATEADD(MONTH, -1, CAST(GETDATE() AS DATE)), NULL,
                 N'TEST-M5-CU', N'生效');
            SET @pid7 = SCOPE_IDENTITY();

            DECLARE @out7 INT;
            EXEC dbo.usp_M5_CreateApplication
                 @elder_id = 1, @policy_id = @pid7, @settle_cycle = '2026-11',
                 @create_by = N'验收脚本', @application_id = @out7 OUTPUT;
            SET @ok7 = 0;
            IF @@TRANCOUNT > 0 ROLLBACK;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            IF ERROR_NUMBER() = 52116 SET @ok7 = 1;
            SET @det7 = LEFT(ERROR_MESSAGE(), 150);
        END CATCH;

        INSERT #res (case_name, result, detail)
        VALUES (N'T7 计价口径校验', CASE WHEN @ok7 = 1 THEN N'PASS' ELSE N'FAIL' END,
                CASE WHEN @ok7 = 1
                     THEN N'charge_unit=' + @cu7 + N' 与补贴方式矛盾时被 52116 拦截'
                     ELSE N'未被拦截：' + ISNULL(@det7, N'申报被接受') END);
    END
END

-- T8 机构级限制：机构被限制后，旗下所有护工都进入限制接单视图
DECLARE @ok8 BIT = 0, @det8 NVARCHAR(200) = N'',
        @org8 INT, @ins8 INT, @rid8 INT, @need8 INT, @got8 INT, @u8 INT, @ord8 INT;

IF OBJECT_ID(N'dbo.caregiver', N'U') IS NULL OR OBJECT_ID(N'dbo.sys_user', N'U') IS NULL
   OR OBJECT_ID(N'dbo.service_order', N'U') IS NULL
    INSERT #res (case_name, result, detail)
    VALUES (N'T8 机构级限制扩散', N'SKIP', N'缺 caregiver / sys_user / service_order，跳过');
ELSE
BEGIN
    SELECT @u8 = MIN(user_id) FROM dbo.sys_user;
    SELECT @ord8 = MIN(order_id) FROM dbo.service_order;

    -- 选一个护工数最多的机构，便于验证「全员受限」
    SELECT TOP 1 @org8 = org_id, @need8 = COUNT(*)
    FROM dbo.caregiver
    GROUP BY org_id
    ORDER BY COUNT(*) DESC, org_id;

    IF @org8 IS NULL OR @u8 IS NULL OR @ord8 IS NULL
        INSERT #res (case_name, result, detail)
        VALUES (N'T8 机构级限制扩散', N'SKIP', N'护工/账号/订单数据不足，跳过');
    ELSE
    BEGIN
        BEGIN TRY
            BEGIN TRAN;
            -- 造一条订单类抽查，再按机构追责建机构级整改
            INSERT dbo.quality_inspection
                (object_type, order_id, caregiver_id, inspect_method, inspect_source, inspect_time,
                 inspector_id, inspector_org, score, authenticity, inspect_result, inspect_status)
            VALUES
                (N'订单', @ord8, NULL, N'上门核查', N'专项整治', SYSDATETIME(),
                 @u8, N'区民政局监管科', 60, N'真实', N'不合格', N'已完成');
            SET @ins8 = SCOPE_IDENTITY();

            EXEC dbo.usp_M5_CreateRectification
                 @inspection_id = @ins8, @caregiver_id = NULL, @org_id = @org8,
                 @problem_desc = N'验收脚本：机构级抽查不合格', @rectify_id = @rid8 OUTPUT;

            SET @got8 = (SELECT COUNT(*) FROM dbo.vw_M5_CaregiverBlocked
                         WHERE org_id = @org8 AND block_level LIKE N'%机构%');
            IF @got8 >= @need8 AND @need8 > 0 SET @ok8 = 1;
            SET @det8 = N'机构 护工 ' + CAST(@need8 AS NVARCHAR(6)) + N' 名，视图命中 ' +
                        CAST(@got8 AS NVARCHAR(6)) + N' 名（block_level 含机构级）';
            ROLLBACK;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            SET @det8 = N'异常：' + LEFT(ERROR_MESSAGE(), 120);
        END CATCH;

        INSERT #res (case_name, result, detail)
        VALUES (N'T8 机构级限制扩散', CASE WHEN @ok8 = 1 THEN N'PASS' ELSE N'FAIL' END, @det8);
    END
END

-- T9 机构级整改：创建 → 提交 → 复查通过，该机构的机构级限制解除
--    ⚠ 必须先「提交整改」（写 submit_time、状态转待复查）再复查：
--      CK_M5_rect_submit 要求状态离开「待整改/整改中/逾期未改」时 submit_time 非空，
--      直接复查会撞 547。
DECLARE @ok9 BIT = 0, @det9 NVARCHAR(200) = N'',
        @org9 INT, @ins9 INT, @rid9 INT, @need9 INT, @bef9 INT, @aft9 INT, @u9 INT,
        @ord9 INT, @st9 NVARCHAR(10), @sub9 DATETIME2, @flag9 CHAR(1);

IF OBJECT_ID(N'dbo.caregiver', N'U') IS NULL OR OBJECT_ID(N'dbo.sys_user', N'U') IS NULL
   OR OBJECT_ID(N'dbo.service_order', N'U') IS NULL
    INSERT #res (case_name, result, detail)
    VALUES (N'T9 机构级解除', N'SKIP', N'缺 caregiver / sys_user / service_order，跳过');
ELSE
BEGIN
    SELECT @u9 = MIN(user_id) FROM dbo.sys_user;
    SELECT @ord9 = MIN(order_id) FROM dbo.service_order;

    -- 挑一个当前没有机构级限制的机构，避免与既有数据互相干扰
    SELECT TOP 1 @org9 = c.org_id, @need9 = COUNT(*)
    FROM dbo.caregiver AS c
    WHERE NOT EXISTS (
            SELECT 1 FROM dbo.rectification AS r
            WHERE r.org_id = c.org_id AND r.rectify_scope = N'机构'
              AND r.restrict_flag = 'Y' AND r.rectify_status <> N'复查通过')
    GROUP BY c.org_id
    ORDER BY c.org_id;

    IF @org9 IS NULL OR @u9 IS NULL OR @ord9 IS NULL
        INSERT #res (case_name, result, detail)
        VALUES (N'T9 机构级解除', N'SKIP', N'无「当前未受限」的机构可测，跳过');
    ELSE
    BEGIN
        BEGIN TRY
            BEGIN TRAN;
            INSERT dbo.quality_inspection
                (object_type, order_id, caregiver_id, inspect_method, inspect_source, inspect_time,
                 inspector_id, inspector_org, score, authenticity, inspect_result, inspect_status)
            VALUES
                (N'订单', @ord9, NULL, N'系统稽核', N'专项整治', SYSDATETIME(),
                 @u9, N'区民政局监管科', 55, N'真实', N'不合格', N'已完成');
            SET @ins9 = SCOPE_IDENTITY();

            EXEC dbo.usp_M5_CreateRectification
                 @inspection_id = @ins9, @caregiver_id = NULL, @org_id = @org9,
                 @problem_desc = N'验收脚本：机构级抽查不合格', @rectify_id = @rid9 OUTPUT;

            SET @bef9 = (SELECT COUNT(*) FROM dbo.vw_M5_CaregiverBlocked
                         WHERE org_id = @org9 AND block_level LIKE N'%机构%');

            -- ① 责任方提交整改：写 submit_time、状态转「待复查」，限制不解除
            EXEC dbo.usp_M5_SubmitRectification
                 @rectify_id = @rid9, @submit_note = N'验收脚本：已补全服务记录并提交佐证材料',
                 @rectify_status = @st9 OUTPUT;

            SELECT @sub9 = submit_time, @flag9 = restrict_flag
            FROM dbo.rectification WHERE rectify_id = @rid9;

            IF @sub9 IS NULL OR @st9 <> N'待复查' OR @flag9 <> 'Y'
            BEGIN
                -- ① 提交结果不符：立即判定失败并回滚，杜绝异常路径误报 PASS
                SET @ok9 = 0;
                SET @det9 = N'提交整改异常：状态 ' + ISNULL(@st9, N'NULL') +
                            N'，restrict_flag ' + ISNULL(@flag9, N'NULL') + N'（应为 待复查 / Y）';
                ROLLBACK;
            END;
            ELSE
            BEGIN
                -- ② 复查通过 → 触发器置 restrict_flag = 'N'
                EXEC dbo.usp_M5_ReviewRectification
                     @rectify_id = @rid9, @reviewer_id = @u9, @review_result = N'通过',
                     @remark = N'验收脚本：整改完成，解除机构限制';

                SET @aft9 = (SELECT COUNT(*) FROM dbo.vw_M5_CaregiverBlocked
                             WHERE org_id = @org9 AND block_level LIKE N'%机构%');

                IF @bef9 = @need9 AND @bef9 > 0 AND @aft9 = 0 SET @ok9 = 1;
                IF @det9 = N''
                    SET @det9 = N'提交后 待复查/Y；解除前机构级命中 ' + CAST(@bef9 AS NVARCHAR(6)) +
                                N' 名，复查通过后 ' + CAST(@aft9 AS NVARCHAR(6)) + N' 名';
                ROLLBACK;
            END;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            SET @ok9 = 0;   -- 任何异常一律不判 PASS
            SET @det9 = N'异常：' + LEFT(ERROR_MESSAGE(), 120);
        END CATCH;

        INSERT #res (case_name, result, detail)
        VALUES (N'T9 机构级解除', CASE WHEN @ok9 = 1 THEN N'PASS' ELSE N'FAIL' END, @det9);
    END
END

-- T10 限制只影响新派单：整改/限制全过程不得改动任何已有订单
DECLARE @ok10 BIT = 0, @det10 NVARCHAR(200) = N'',
        @sum_before BIGINT, @sum_after BIGINT, @org10 INT, @ins10 INT, @rid10 INT,
        @u10 INT, @ord10 INT;

IF OBJECT_ID(N'dbo.service_order', N'U') IS NULL OR OBJECT_ID(N'dbo.sys_user', N'U') IS NULL
    INSERT #res (case_name, result, detail)
    VALUES (N'T10 已有订单不受影响', N'SKIP', N'缺 service_order / sys_user，跳过');
ELSE
BEGIN
    SELECT @u10 = MIN(user_id) FROM dbo.sys_user;
    SELECT @ord10 = MIN(order_id) FROM dbo.service_order;
    SELECT @org10 = MIN(org_id) FROM dbo.service_org;

    IF @u10 IS NULL OR @ord10 IS NULL OR @org10 IS NULL
        INSERT #res (case_name, result, detail)
        VALUES (N'T10 已有订单不受影响', N'SKIP', N'机构/账号/订单数据不足，跳过');
    ELSE
    BEGIN
        BEGIN TRY
            BEGIN TRAN;
            SELECT @sum_before = ISNULL(CHECKSUM_AGG(BINARY_CHECKSUM(
                       order_id, order_status, confirm_status, total_amount, appointment_time)), 0)
            FROM dbo.service_order;

            INSERT dbo.quality_inspection
                (object_type, order_id, caregiver_id, inspect_method, inspect_source, inspect_time,
                 inspector_id, inspector_org, score, authenticity, inspect_result, inspect_status)
            VALUES
                (N'订单', @ord10, NULL, N'电话回访', N'投诉转办', SYSDATETIME(),
                 @u10, N'区民政局监管科', 58, N'部分真实', N'不合格', N'已完成');
            SET @ins10 = SCOPE_IDENTITY();

            EXEC dbo.usp_M5_CreateRectification
                 @inspection_id = @ins10, @caregiver_id = NULL, @org_id = @org10,
                 @rectify_id = @rid10 OUTPUT;

            SELECT @sum_after = ISNULL(CHECKSUM_AGG(BINARY_CHECKSUM(
                       order_id, order_status, confirm_status, total_amount, appointment_time)), 0)
            FROM dbo.service_order;

            IF @sum_before = @sum_after SET @ok10 = 1;
            SET @det10 = CASE WHEN @ok10 = 1
                              THEN N'机构级整改创建前后订单表校验和一致，仅影响新派单判断'
                              ELSE N'订单表被改动：' + CAST(@sum_before AS NVARCHAR(20)) + N' → ' +
                                   CAST(@sum_after AS NVARCHAR(20)) END;
            ROLLBACK;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            SET @det10 = N'异常：' + LEFT(ERROR_MESSAGE(), 120);
        END CATCH;

        INSERT #res (case_name, result, detail)
        VALUES (N'T10 已有订单不受影响', CASE WHEN @ok10 = 1 THEN N'PASS' ELSE N'FAIL' END, @det10);
    END
END

-- T11 审核任务预分配（usp_M5_AssignAuditor）：
--   ① 角色与节点不匹配（街道复审员 指派到 待社区初审）应被 52173 拦截；
--   ② 角色匹配（社区管理员 指派到 待社区初审）应写入 current_auditor_id 并回传。
IF OBJECT_ID(N'dbo.sys_user', N'U') IS NULL
    INSERT #res (case_name, result, detail)
    VALUES (N'T11 审核任务预分配', N'SKIP', N'缺 sys_user，跳过');
ELSE
BEGIN
    DECLARE @app11 INT, @good11 INT, @bad11 INT,
            @st11 INT = 0, @msg11 NVARCHAR(200), @back11 INT;

    SELECT TOP 1 @app11 = application_id
    FROM dbo.subsidy_application
    WHERE audit_status = N'待社区初审'
    ORDER BY application_id;
    SELECT TOP 1 @good11 = user_id FROM dbo.sys_user
    WHERE role_code = N'COMMUNITY_ADMIN' ORDER BY user_id;
    SELECT TOP 1 @bad11 = user_id FROM dbo.sys_user
    WHERE role_code = N'STREET_SUPERVISOR' ORDER BY user_id;

    IF @app11 IS NULL OR @good11 IS NULL OR @bad11 IS NULL
        INSERT #res (case_name, result, detail)
        VALUES (N'T11 审核任务预分配', N'SKIP', N'缺「待社区初审」申报单或社区/街道账号，跳过');
    ELSE
    BEGIN
        -- ① 角色不匹配 → 52173
        BEGIN TRY
            BEGIN TRAN;
            EXEC dbo.usp_M5_AssignAuditor @application_id = @app11, @assignee_id = @bad11;
            ROLLBACK;
            SET @msg11 = N'角色不匹配的指派未被拦截';
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            IF ERROR_NUMBER() = 52173 SET @st11 += 1;
            ELSE SET @msg11 = N'角色不匹配拦截错误码异常：' + CAST(ERROR_NUMBER() AS NVARCHAR(10));
        END CATCH;

        -- ② 角色匹配 → 写入成功
        BEGIN TRY
            BEGIN TRAN;
            EXEC dbo.usp_M5_AssignAuditor @application_id = @app11, @assignee_id = @good11,
                                          @assigned_to = @back11 OUTPUT;
            IF @back11 = @good11
               AND (SELECT current_auditor_id FROM dbo.subsidy_application
                     WHERE application_id = @app11) = @good11
                SET @st11 += 1;
            ELSE SET @msg11 = N'指派后 current_auditor_id 未生效';
            ROLLBACK;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            SET @msg11 = ISNULL(@msg11, ERROR_MESSAGE());
        END CATCH;

        INSERT #res (case_name, result, detail)
        VALUES (N'T11 审核任务预分配',
                CASE WHEN @st11 = 2 THEN N'PASS' ELSE N'FAIL' END,
                CASE WHEN @st11 = 2 THEN N'角色不匹配被 52173 拦截；匹配指派写入 current_auditor_id'
                     ELSE ISNULL(@msg11, N'用例异常') END);
    END
END

-- T12 审核节点流转即清空（usp_M5_AuditAdvance）：
--   ① 预指派 current_auditor_id 后流转（待社区初审 → 街道复审中）：
--      状态流转、current_auditor_id 清空、日志保留实际审核人，三者同事务生效；
--   ② 期望状态与实际不符（并发冲突模拟）应被 52175 拦截。
IF OBJECT_ID(N'dbo.usp_M5_AuditAdvance', N'P') IS NULL
    INSERT #res (case_name, result, detail)
    VALUES (N'T12 节点流转清空指派', N'FAIL', N'缺 usp_M5_AuditAdvance（依赖过程缺失一律判 FAIL，不 SKIP）');
ELSE
BEGIN
    DECLARE @app12 INT, @aud12 INT, @st12 INT = 0, @msg12 NVARCHAR(200);

    SELECT TOP 1 @app12 = application_id
    FROM dbo.subsidy_application
    WHERE audit_status = N'待社区初审'
    ORDER BY application_id;
    SELECT TOP 1 @aud12 = user_id FROM dbo.sys_user
    WHERE role_code = N'COMMUNITY_ADMIN' ORDER BY user_id;

    IF @app12 IS NULL OR @aud12 IS NULL
        INSERT #res (case_name, result, detail)
        VALUES (N'T12 节点流转清空指派', N'SKIP', N'缺「待社区初审」申报单或社区账号，跳过');
    ELSE
    BEGIN
        -- ① 预指派 → 流转 → 清空 + 日志
        BEGIN TRY
            BEGIN TRAN;
            UPDATE dbo.subsidy_application
               SET current_auditor_id = @aud12
             WHERE application_id = @app12;
            EXEC dbo.usp_M5_AuditAdvance
                 @application_id = @app12, @before_status = N'待社区初审',
                 @after_status = N'街道复审中', @audit_node = N'社区初审',
                 @audit_action = N'通过', @auditor_id = @aud12, @auditor_org = N'验收测试';
            IF (SELECT audit_status FROM dbo.subsidy_application
                 WHERE application_id = @app12) = N'街道复审中'
               AND (SELECT current_auditor_id FROM dbo.subsidy_application
                     WHERE application_id = @app12) IS NULL
               AND EXISTS (SELECT 1 FROM dbo.subsidy_audit_log
                            WHERE application_id = @app12 AND audit_node = N'社区初审'
                              AND auditor_id = @aud12 AND after_status = N'街道复审中')
                SET @st12 += 1;
            ELSE SET @msg12 = N'流转后状态/清空/日志校验未全部满足';
            ROLLBACK;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            SET @msg12 = ISNULL(@msg12, ERROR_MESSAGE());
        END CATCH;

        -- ② 期望状态不符（并发冲突模拟）→ 52175
        BEGIN TRY
            BEGIN TRAN;
            EXEC dbo.usp_M5_AuditAdvance
                 @application_id = @app12, @before_status = N'审核通过',
                 @after_status = N'民政终审中', @audit_node = N'街道复审',
                 @audit_action = N'通过', @auditor_id = @aud12, @auditor_org = N'验收测试';
            ROLLBACK;
            SET @msg12 = ISNULL(@msg12, N'状态不符的流转未被拦截');
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            IF ERROR_NUMBER() = 52175 SET @st12 += 1;
            ELSE SET @msg12 = N'状态不符拦截错误码异常：' + CAST(ERROR_NUMBER() AS NVARCHAR(10));
        END CATCH;

        INSERT #res (case_name, result, detail)
        VALUES (N'T12 节点流转清空指派',
                CASE WHEN @st12 = 2 THEN N'PASS' ELSE N'FAIL' END,
                CASE WHEN @st12 = 2 THEN N'流转后 current_auditor_id 清空且日志保留审核人；状态不符被 52175 拦截'
                     ELSE ISNULL(@msg12, N'用例异常') END);
    END
END

-- T13 方案A：复查不通过可重新提交（创建 → 提交 → 复查不通过 → 再次提交 → 待复查；限制保持 Y）
DECLARE @ok13 BIT = 0, @det13 NVARCHAR(200) = N'',
        @org13 INT, @ins13 INT, @rid13 INT, @ord13 INT, @u13 INT,
        @st13 NVARCHAR(10), @flag13 CHAR(1);
IF (SELECT COUNT(*) FROM dbo.sys_user) = 0
   OR (SELECT COUNT(*) FROM dbo.service_order) = 0
   OR (SELECT COUNT(*) FROM dbo.service_org) = 0
    INSERT #res (case_name, result, detail)
    VALUES (N'T13 复查不通过重新提交', N'SKIP', N'缺 sys_user / service_order / service_org，跳过');
ELSE
BEGIN
    SELECT @u13 = MIN(user_id) FROM dbo.sys_user;
    SELECT @ord13 = MIN(order_id) FROM dbo.service_order;
    SELECT TOP 1 @org13 = org_id FROM dbo.service_org ORDER BY org_id;

    BEGIN TRY
        BEGIN TRAN;
        INSERT dbo.quality_inspection
            (object_type, order_id, caregiver_id, inspect_method, inspect_source, inspect_time,
             inspector_id, inspector_org, score, authenticity, inspect_result, inspect_status)
        VALUES
            (N'订单', @ord13, NULL, N'系统稽核', N'专项整治', SYSDATETIME(),
             @u13, N'区民政局监管科', 55, N'真实', N'不合格', N'已完成');
        SET @ins13 = SCOPE_IDENTITY();

        EXEC dbo.usp_M5_CreateRectification
             @inspection_id = @ins13, @caregiver_id = NULL, @org_id = @org13,
             @problem_desc = N'验收脚本：T13 机构级抽查不合格', @rectify_id = @rid13 OUTPUT;

        -- 第一次提交 + 复查不通过
        EXEC dbo.usp_M5_SubmitRectification
             @rectify_id = @rid13, @submit_note = N'验收脚本：T13 第一次提交',
             @rectify_status = @st13 OUTPUT;
        EXEC dbo.usp_M5_ReviewRectification
             @rectify_id = @rid13, @reviewer_id = @u13, @review_result = N'不通过',
             @remark = N'验收脚本：T13 复查不通过';

        SELECT @st13 = rectify_status, @flag13 = restrict_flag
        FROM dbo.rectification WHERE rectify_id = @rid13;
        IF @st13 <> N'复查不通过' OR @flag13 <> 'Y'
            THROW 52998, N'T13 前置异常：复查不通过后状态/限制标志不符。', 1;

        -- 方案A：复查不通过可重新提交
        EXEC dbo.usp_M5_SubmitRectification
             @rectify_id = @rid13, @submit_note = N'验收脚本：T13 返工后重新提交',
             @rectify_status = @st13 OUTPUT;

        SELECT @flag13 = restrict_flag
        FROM dbo.rectification WHERE rectify_id = @rid13;

        IF @st13 = N'待复查' AND @flag13 = 'Y' SET @ok13 = 1;
        SET @det13 = CASE WHEN @ok13 = 1
                          THEN N'复查不通过 → 重新提交成功（待复查），限制保持 Y，可再次复查'
                          ELSE N'重新提交后状态 ' + ISNULL(@st13, N'NULL') +
                               N'，restrict_flag ' + ISNULL(@flag13, N'NULL') END;
        ROLLBACK;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @ok13 = 0;   -- 任何异常一律不判 PASS
        SET @det13 = N'异常：' + LEFT(ERROR_MESSAGE(), 120);
    END CATCH;

    INSERT #res (case_name, result, detail)
    VALUES (N'T13 复查不通过重新提交',
            CASE WHEN @ok13 = 1 THEN N'PASS' ELSE N'FAIL' END, @det13);
END

-- 汇总
SELECT seq AS 序号, case_name AS 测试项, result AS 结果, detail AS 说明 FROM #res ORDER BY seq;

DECLARE @pass INT = (SELECT COUNT(*) FROM #res WHERE result = N'PASS'),
        @fail INT = (SELECT COUNT(*) FROM #res WHERE result = N'FAIL'),
        @skip INT = (SELECT COUNT(*) FROM #res WHERE result = N'SKIP');

PRINT N'成员5 业务测试汇总：PASS ' + CAST(@pass AS NVARCHAR(10)) +
      N' / FAIL ' + CAST(@fail AS NVARCHAR(10)) +
      N' / SKIP ' + CAST(@skip AS NVARCHAR(10));

IF @fail > 0
    THROW 52310, N'存在 FAIL 项，请按上表逐项排查。', 1;
PRINT N'PASS 部署验收';
GO
