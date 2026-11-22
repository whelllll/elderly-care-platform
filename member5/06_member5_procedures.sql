-- =============================================================
-- 成员5 补贴核算与质量监管  |  06 触发器与存储过程
-- 业务规则自动化：
--   ① TR_M5_Item_Guard        明细入库即校验（金额勾稽 / 工时缺失 / 项目资格）
--   ② usp_M5_CreateApplication 同老人·同周期·同项目 防重复申报
--   ③ usp_M5_RefreshTotals    明细变动后回写申报头汇总
--   ④ usp_M5_SyncRestrictFlag 限制接单标志回填 / 修复工具（不自行提交事务）
--   ⑤ TR_M5_Rect_SyncFlag     整改状态 → restrict_flag 同事务自动同步
--   ⑥ usp_M5_LockScope        统一加锁顺序：机构 → 护工（与成员2 派单模块共用）
--   ⑦ usp_M5_CreateRectification 新增整改单（护工级 / 机构级），事务 + 行级锁
--   ⑧ usp_M5_SubmitRectification 责任方提交整改：写 submit_time、状态转「待复查」，限制不解除
--   ⑨ usp_M5_ReviewRectification 整改复查，通过即解除限制，不影响已接订单
--   ⑩ usp_M5_AssignAuditor      审核任务预分配（节点×角色校验 + UPDLOCK 行锁）
-- =============================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'dbo.TR_M5_Item_Guard', N'TR') IS NOT NULL
    DROP TRIGGER dbo.TR_M5_Item_Guard;
GO
CREATE TRIGGER dbo.TR_M5_Item_Guard
ON dbo.subsidy_application_item
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- 规则1：补贴 + 自付 不得超过服务金额（金额勾稽）
    IF EXISTS (SELECT 1 FROM inserted
               WHERE subsidy_amount + self_pay_amount > service_amount)
    BEGIN
        THROW 52100, N'明细金额勾稽失败：补贴金额 + 自付金额 不得超过服务金额。', 1;
    END;

    -- 规则2：可补贴项目资格校验（is_subsidizable = 0 的项目不得计入）
    IF EXISTS (
        SELECT 1
        FROM inserted AS n
        JOIN dbo.service_order AS o ON o.order_id = n.order_id
        JOIN dbo.service_item  AS si ON si.service_id = o.service_id
        WHERE si.is_subsidizable = 0)
    BEGIN
        THROW 52101, N'该服务项目不具备补贴资格（service_item.is_subsidizable = 0），不得计入申报明细。', 1;
    END;

    -- 规则3：缺有效工时的明细自动标记，不再保留“通过”
    UPDATE i
       SET verify_result = N'工时缺失'
    FROM dbo.subsidy_application_item AS i
    JOIN inserted AS n ON n.item_id = i.item_id
    WHERE (n.work_id IS NULL OR n.valid_hours IS NULL OR n.valid_hours <= 0)
      AND i.verify_result = N'通过';
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_M5_CreateApplication
    @elder_id       INT,
    @policy_id      INT,
    @settle_cycle   CHAR(7),
    @create_by      NVARCHAR(20),
    @application_id INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @item_id INT, @cycle_start DATE, @cycle_end DATE,
            @status NVARCHAR(8), @eff DATE, @exp DATE;

    SELECT @item_id = service_item_id, @status = policy_status,
           @eff = effective_date, @exp = expire_date
    FROM dbo.subsidy_policy WHERE policy_id = @policy_id;

    IF @item_id IS NULL THROW 52110, N'补贴政策不存在。', 1;
    IF @status <> N'生效' THROW 52111, N'补贴政策非“生效”状态，不可申报。', 1;

    SET @cycle_start = TRY_CONVERT(DATE, @settle_cycle + N'-01');
    IF @cycle_start IS NULL THROW 52112, N'结算周期格式应为 yyyy-mm。', 1;
    SET @cycle_end = EOMONTH(@cycle_start);

    IF @eff > @cycle_end OR (@exp IS NOT NULL AND @exp < @cycle_start)
        THROW 52113, N'结算周期不在政策有效期内。', 1;

    -- 规则5：计价口径校验（成员2 service_item.charge_unit ↔ 本表 subsidy_mode）
    -- 服务项目按“次”计价时，补贴标准是每次定额，不能用“按工时”；
    -- 服务项目按“小时”计价时，补贴标准是每小时单价，不能用“按次定额”。
    -- 按月定额属包干口径，与计价单位无关，两种项目都允许。
    DECLARE @charge_unit NVARCHAR(10), @mode NVARCHAR(10);
    IF OBJECT_ID(N'dbo.service_item', N'U') IS NOT NULL
    BEGIN
        SELECT @charge_unit = si.charge_unit, @mode = p.subsidy_mode
        FROM dbo.subsidy_policy AS p
        JOIN dbo.service_item  AS si ON si.service_id = p.service_item_id
        WHERE p.policy_id = @policy_id;

        IF @charge_unit IS NOT NULL
           AND ((@charge_unit = N'次'   AND @mode = N'按工时')
             OR (@charge_unit = N'小时' AND @mode = N'按次定额'))
            THROW 52116, N'补贴方式与服务项目计价单位不匹配：按次计价的项目不能用“按工时”，按小时计价的项目不能用“按次定额”。', 1;
    END;

    BEGIN TRY
        BEGIN TRAN;

        -- 规则4：同老人·同周期·同项目 不得重复申报
        IF EXISTS (
            SELECT 1
            FROM dbo.subsidy_application AS a
            JOIN dbo.subsidy_policy AS p ON p.policy_id = a.policy_id
            WHERE a.elder_id = @elder_id
              AND a.settle_cycle = @settle_cycle
              AND p.service_item_id = @item_id
              AND a.audit_status <> N'审核驳回')
        BEGIN
            THROW 52114, N'同老人·同周期·同项目已存在有效申报，禁止重复申报。', 1;
        END;

        IF EXISTS (SELECT 1 FROM dbo.subsidy_application
                   WHERE elder_id = @elder_id AND policy_id = @policy_id
                     AND settle_cycle = @settle_cycle)
            THROW 52115, N'同老人·同政策·同周期申报已存在。', 1;

        INSERT dbo.subsidy_application
            (elder_id, policy_id, settle_cycle, application_amount, self_pay_amount,
             order_count, total_hours, apply_type, audit_status, create_by)
        VALUES
            (@elder_id, @policy_id, @settle_cycle, 0, 0, 0, 0, N'系统汇总', N'待社区初审', @create_by);

        SET @application_id = SCOPE_IDENTITY();

        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_M5_RefreshTotals
    @application_id INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.subsidy_application WHERE application_id = @application_id)
        THROW 52120, N'申报单不存在。', 1;

    UPDATE a
       SET order_count        = ISNULL(s.cnt, 0),
           total_hours        = ISNULL(s.hours, 0),
           application_amount = ISNULL(s.subsidy, 0),
           self_pay_amount    = ISNULL(s.selfpay, 0)
    FROM dbo.subsidy_application AS a
    LEFT JOIN (
        SELECT application_id,
               COUNT(*) AS cnt,
               SUM(ISNULL(valid_hours, 0)) AS hours,
               SUM(subsidy_amount) AS subsidy,
               SUM(self_pay_amount) AS selfpay
        FROM dbo.subsidy_application_item
        WHERE application_id = @application_id
        GROUP BY application_id
    ) AS s ON s.application_id = a.application_id
    WHERE a.application_id = @application_id;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_M5_SyncRestrictFlag
    @rectify_id INT = NULL,
    @all        BIT = 0
AS
BEGIN
    -- restrict_flag 的正常同步由触发器 TR_M5_Rect_SyncFlag 在同一语句、同一事务内完成。
    -- 本过程只用于：① 历史数据回填；② 异常数据修复；③ 测试脚本显式重建标志。
    -- 本过程不自行开启/提交事务，由调用方统一管理（与全组「事务 + 行级锁」约定一致）。
    SET NOCOUNT ON;

    IF @rectify_id IS NULL AND @all = 0
        THROW 52130, N'请指定 @rectify_id，或置 @all = 1 做全表回填。', 1;

    IF @rectify_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM dbo.rectification WHERE rectify_id = @rectify_id)
        THROW 52131, N'整改记录不存在。', 1;

    UPDATE r
       SET restrict_flag = CASE WHEN r.rectify_status = N'复查通过' THEN 'N' ELSE 'Y' END,
           release_time  = CASE WHEN r.rectify_status = N'复查通过'
                                THEN ISNULL(r.release_time, SYSDATETIME()) ELSE NULL END
    FROM dbo.rectification AS r
    WHERE (@all = 1 OR r.rectify_id = @rectify_id)
      AND (r.restrict_flag <> CASE WHEN r.rectify_status = N'复查通过' THEN 'N' ELSE 'Y' END
        OR (r.rectify_status =  N'复查通过' AND r.release_time IS NULL)
        OR (r.rectify_status <> N'复查通过' AND r.release_time IS NOT NULL));
END;
GO

-- =============================================================
-- ⑤ TR_M5_Rect_SyncFlag  整改状态 → 限制接单标志 自动同步
--    任何写入路径（存储过程、脚本、人工修数）都保证 restrict_flag 与整改状态一致，
--    且同步与业务写入在**同一条语句、同一个事务**内完成，
--    不会出现「状态改了但标志没改」的中间态。
-- =============================================================
IF OBJECT_ID(N'dbo.TR_M5_Rect_SyncFlag', N'TR') IS NOT NULL
    DROP TRIGGER dbo.TR_M5_Rect_SyncFlag;
GO
CREATE TRIGGER dbo.TR_M5_Rect_SyncFlag
ON dbo.rectification
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- 触发器内部回写本表时不再递归
    IF TRIGGER_NESTLEVEL() > 1 RETURN;

    UPDATE r
       SET restrict_flag = CASE WHEN i.rectify_status = N'复查通过' THEN 'N' ELSE 'Y' END,
           release_time  = CASE WHEN i.rectify_status = N'复查通过'
                                THEN ISNULL(r.release_time, SYSDATETIME()) ELSE NULL END
    FROM dbo.rectification AS r
    JOIN inserted AS i ON i.rectify_id = r.rectify_id
    WHERE r.restrict_flag <> CASE WHEN i.rectify_status = N'复查通过' THEN 'N' ELSE 'Y' END
       OR (i.rectify_status =  N'复查通过' AND r.release_time IS NULL)
       OR (i.rectify_status <> N'复查通过' AND r.release_time IS NOT NULL);
END;
GO

-- =============================================================
-- ⑥ usp_M5_LockScope  统一加锁顺序（机构 → 护工）
--    与成员2 派单/改派模块共用同一顺序，避免两边交叉加锁产生死锁。
--    ⚠ 必须在事务内调用，锁才会持有到事务结束；本过程不自行开事务。
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.usp_M5_LockScope
    @org_id       INT,
    @caregiver_id INT = NULL,
    @locked       BIT = 0 OUTPUT,
    @reason       NVARCHAR(100) = N'' OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @locked = 0;
    SET @reason = N'';

    IF @@TRANCOUNT = 0
        THROW 52150, N'usp_M5_LockScope 必须在事务内调用，否则锁立即释放。', 1;

    -- 第一步：锁机构（service_org）
    IF NOT EXISTS (SELECT 1 FROM dbo.service_org WITH (UPDLOCK, HOLDLOCK)
                   WHERE org_id = @org_id)
    BEGIN
        SET @reason = N'机构不存在';
        RETURN;
    END;

    -- 第二步：锁护工（caregiver），并复核归属机构未被改动
    IF @caregiver_id IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.caregiver WITH (UPDLOCK, HOLDLOCK)
                       WHERE caregiver_id = @caregiver_id)
        BEGIN
            SET @reason = N'护工不存在';
            RETURN;
        END;

        IF NOT EXISTS (SELECT 1 FROM dbo.caregiver
                       WHERE caregiver_id = @caregiver_id AND org_id = @org_id)
        BEGIN
            SET @reason = N'护工不属于该机构';
            RETURN;
        END;
    END;

    SET @locked = 1;
END;
GO

-- =============================================================
-- ⑦ usp_M5_CreateRectification  新增整改单（护工级 / 机构级）
--    事务 + 行级锁：先锁机构、再锁护工 → 插入整改 → 触发器同步 restrict_flag
--    @caregiver_id = NULL 表示机构级整改（限制该机构下全部护工接新单）
--    外层已有事务时自动并入外层事务，不单独提交
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.usp_M5_CreateRectification
    @inspection_id INT,
    @caregiver_id  INT = NULL,
    @org_id        INT = NULL,
    @problem_desc  NVARCHAR(200) = NULL,
    @requirement   NVARCHAR(200) = NULL,
    @deadline      DATE = NULL,
    @rectify_id    INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @scope NVARCHAR(4), @tran_owner BIT = 0, @locked BIT, @reason NVARCHAR(100),
            @org INT, @cg_org INT, @desc NVARCHAR(200), @req NVARCHAR(200), @dl DATE;

    IF OBJECT_ID(N'dbo.rectification', N'U') IS NULL
        THROW 52151, N'请先执行 01_member5_tables.sql。', 1;

    IF NOT EXISTS (SELECT 1 FROM dbo.quality_inspection WHERE inspection_id = @inspection_id)
        THROW 52152, N'抽查记录不存在，无法生成整改单。', 1;

    IF @caregiver_id IS NULL
    BEGIN
        SET @scope = N'机构';
        IF @org_id IS NULL
            THROW 52153, N'机构级整改必须指定 @org_id。', 1;
        SET @org = @org_id;
    END
    ELSE
    BEGIN
        SET @scope = N'护工';
        SELECT @cg_org = org_id FROM dbo.caregiver WHERE caregiver_id = @caregiver_id;
        IF @cg_org IS NULL
            THROW 52154, N'护工不存在，无法生成护工级整改。', 1;
        IF @org_id IS NOT NULL AND @org_id <> @cg_org
            THROW 52155, N'护工归属机构与传入 @org_id 不一致。', 1;
        SET @org = @cg_org;
    END;

    IF EXISTS (SELECT 1 FROM dbo.rectification
               WHERE inspection_id = @inspection_id AND rectify_status <> N'复查通过')
        THROW 52156, N'该抽查记录已存在未完结的整改单，不能重复创建。', 1;

    SET @desc = ISNULL(@problem_desc, N'抽查发现服务质量问题，需整改。');
    SET @req  = ISNULL(@requirement,  N'按抽查意见完成整改并提交佐证材料。');
    SET @dl   = ISNULL(@deadline, DATEADD(DAY, 7, CAST(SYSDATETIME() AS DATE)));

    IF @@TRANCOUNT = 0
    BEGIN
        BEGIN TRAN;
        SET @tran_owner = 1;
    END;

    BEGIN TRY
        EXEC dbo.usp_M5_LockScope @org_id = @org, @caregiver_id = @caregiver_id,
                                  @locked = @locked OUTPUT, @reason = @reason OUTPUT;
        IF @locked = 0
            THROW 52157, @reason, 1;

        INSERT dbo.rectification
            (inspection_id, caregiver_id, org_id, rectify_scope, problem_desc,
             rectify_requirement, rectify_deadline, rectify_status, restrict_flag)
        VALUES
            (@inspection_id, @caregiver_id, @org, @scope, @desc, @req, @dl, N'待整改', 'Y');

        SET @rectify_id = SCOPE_IDENTITY();

        IF @tran_owner = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF @tran_owner = 1 AND XACT_STATE() <> 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

-- =============================================================
-- ⑧ usp_M5_SubmitRectification  责任方提交整改
--    整改三态闭环：创建（待整改）→ 提交（待复查）→ 复查（通过/不通过）
--    事务 + 行级锁（机构 → 护工），与创建/复查同序；CK_M5_rect_submit 要求
--    状态离开「待整改/整改中/逾期未改」时 submit_time 必须非空，故复查前必先提交
--    提交只写 submit_time 并把状态转为「待复查」，restrict_flag 保持 'Y'，
--    已接订单继续履行不受影响（本模块不更新 service_order）
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.usp_M5_SubmitRectification
    @rectify_id     INT,
    @submit_note    NVARCHAR(200) = NULL,
    @rectify_status NVARCHAR(10)  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @org INT, @cg INT, @status NVARCHAR(10),
            @tran_owner BIT = 0, @locked BIT, @reason NVARCHAR(100);

    SELECT @org = org_id, @cg = caregiver_id, @status = rectify_status
    FROM dbo.rectification WHERE rectify_id = @rectify_id;

    IF @status IS NULL
        THROW 52164, N'整改记录不存在。', 1;
    IF @status NOT IN (N'待整改', N'整改中', N'逾期未改')
        THROW 52165, N'当前状态不允许提交整改（仅 待整改 / 整改中 / 逾期未改 可提交）。', 1;

    IF @@TRANCOUNT = 0
    BEGIN
        BEGIN TRAN;
        SET @tran_owner = 1;
    END;

    BEGIN TRY
        -- 与创建/复查同序加锁：先机构，后护工
        EXEC dbo.usp_M5_LockScope @org_id = @org, @caregiver_id = @cg,
                                  @locked = @locked OUTPUT, @reason = @reason OUTPUT;
        IF @locked = 0
            THROW 52166, @reason, 1;

        UPDATE dbo.rectification
           SET rectify_status = N'待复查',
               submit_time    = SYSDATETIME(),
               remark         = CASE WHEN @submit_note IS NULL THEN remark
                                     ELSE LEFT(ISNULL(remark + N'；', N'') + @submit_note, 200) END
         WHERE rectify_id = @rectify_id;

        -- 触发器 TR_M5_Rect_SyncFlag 已同步 restrict_flag：状态 ≠ 复查通过 → 保持 'Y'
        SELECT @rectify_status = rectify_status
        FROM dbo.rectification WHERE rectify_id = @rectify_id;

        IF @tran_owner = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF @tran_owner = 1 AND XACT_STATE() <> 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

-- =============================================================
-- ⑨ usp_M5_ReviewRectification  整改复查
--    事务 + 行级锁（机构 → 护工）→ 更新复查结论 → 触发器同步 restrict_flag
--    「通过」＝ 复查通过 → restrict_flag 转 'N'；其余结论继续保持限制
--    限制只影响新派单与新改派，**不触碰任何已有订单**（service_order 只读）
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.usp_M5_ReviewRectification
    @rectify_id    INT,
    @reviewer_id   INT,
    @review_result NVARCHAR(8),
    @remark        NVARCHAR(200) = NULL,
    @restrict_flag CHAR(1) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @org INT, @cg INT, @scope NVARCHAR(4), @status NVARCHAR(10),
            @tran_owner BIT = 0, @locked BIT, @reason NVARCHAR(100), @new_status NVARCHAR(10);

    SELECT @org = org_id, @cg = caregiver_id, @scope = rectify_scope, @status = rectify_status
    FROM dbo.rectification WHERE rectify_id = @rectify_id;

    IF @status IS NULL THROW 52160, N'整改记录不存在。', 1;
    IF @review_result NOT IN (N'通过', N'部分通过', N'不通过')
        THROW 52161, N'复查结论只能是 通过 / 部分通过 / 不通过。', 1;
    IF @status = N'复查通过'
        THROW 52162, N'该整改已复查通过，不能重复复查。', 1;

    SET @new_status = CASE @review_result
                           WHEN N'通过'     THEN N'复查通过'
                           WHEN N'部分通过' THEN N'待整改'
                           ELSE N'复查不通过' END;

    IF @@TRANCOUNT = 0
    BEGIN
        BEGIN TRAN;
        SET @tran_owner = 1;
    END;

    BEGIN TRY
        -- 与派单模块同序加锁：先机构，后护工
        EXEC dbo.usp_M5_LockScope @org_id = @org, @caregiver_id = @cg,
                                  @locked = @locked OUTPUT, @reason = @reason OUTPUT;
        IF @locked = 0
            THROW 52163, @reason, 1;

        UPDATE dbo.rectification
           SET rectify_status = @new_status,
               review_result  = @review_result,
               review_time    = SYSDATETIME(),
               reviewer_id    = @reviewer_id,
               remark         = ISNULL(@remark, remark)
         WHERE rectify_id = @rectify_id;

        -- 触发器已同步 restrict_flag，这里读回实际结果供调用方判断
        SELECT @restrict_flag = restrict_flag FROM dbo.rectification WHERE rectify_id = @rectify_id;

        IF @tran_owner = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF @tran_owner = 1 AND XACT_STATE() <> 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

-- =============================================================
-- ⑩ usp_M5_AssignAuditor  审核任务预分配（跨模块契约：成员2 后端「指派」入口）
--    业务规则（与成员2 对齐的口径）：
--      · 仅 待社区初审 / 街道复审中 两个节点可指派；
--      · 被指派人角色必须与节点匹配：
--          待社区初审  → COMMUNITY_ADMIN
--          街道复审中  → STREET_SUPERVISOR
--      · current_auditor_id 为 NULL 时该节点任意对应角色可认领（先到先得）；
--        非空时仅该指定人可办理，其余人后端拒绝；
--      · UPDLOCK + ROWLOCK 串行化并发指派，以最后一次成功指派为准；
--      · 抽查（quality_inspection）与整改（rectification）无待办池，不适用预分配。
-- =============================================================
CREATE OR ALTER PROCEDURE dbo.usp_M5_AssignAuditor
    @application_id INT,
    @assignee_id    INT,
    @assigned_to    INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @status NVARCHAR(20), @role NVARCHAR(30),
            @need_role NVARCHAR(30), @msg NVARCHAR(200),
            @tran_owner BIT = 0;

    IF @@TRANCOUNT = 0
    BEGIN
        BEGIN TRAN;
        SET @tran_owner = 1;
    END;

    BEGIN TRY
        -- UPDLOCK + ROWLOCK：并发指派互斥，同一张申报单同一时刻只有一个指派生效
        SELECT @status = audit_status
        FROM dbo.subsidy_application WITH (UPDLOCK, ROWLOCK)
        WHERE application_id = @application_id;

        IF @status IS NULL
            THROW 52170, N'申报单不存在。', 1;
        IF @status NOT IN (N'待社区初审', N'街道复审中')
            THROW 52171, N'当前审核状态不允许指派（仅 待社区初审 / 街道复审中 可指派）。', 1;

        SELECT @role = role_code FROM dbo.sys_user WHERE user_id = @assignee_id;
        IF @role IS NULL
            THROW 52172, N'被指派账号不存在。', 1;

        SET @need_role = CASE @status
                             WHEN N'待社区初审' THEN N'COMMUNITY_ADMIN'
                             ELSE N'STREET_SUPERVISOR'
                         END;
        IF @role <> @need_role
        BEGIN
            SET @msg = N'被指派人角色与当前审核节点不匹配（要求 ' + @need_role + N'）。';
            THROW 52173, @msg, 1;
        END;

        UPDATE dbo.subsidy_application
           SET current_auditor_id = @assignee_id
         WHERE application_id = @application_id;

        SET @assigned_to = @assignee_id;

        IF @tran_owner = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF @tran_owner = 1 AND XACT_STATE() <> 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO
