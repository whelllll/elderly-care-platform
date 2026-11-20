-- =============================================================
-- 成员5 补贴核算与质量监管  |  06 触发器与存储过程
-- 业务规则自动化：
--   ① TR_M5_Item_Guard       明细入库即校验（金额勾稽 / 工时缺失 / 项目资格）
--   ② usp_M5_CreateApplication 同老人·同周期·同项目 防重复申报
--   ③ usp_M5_RefreshTotals   明细变动后回写申报头汇总
--   ④ usp_M5_SyncRestrictFlag 整改状态联动限制接单标志
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
    @rectify_id INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status NVARCHAR(10), @result NVARCHAR(8);

    SELECT @status = rectify_status, @result = review_result
    FROM dbo.rectification WHERE rectify_id = @rectify_id;

    IF @status IS NULL THROW 52130, N'整改记录不存在。', 1;

    IF @status = N'复查通过' AND @result = N'通过'
        UPDATE dbo.rectification
           SET restrict_flag = 'N',
               release_time = ISNULL(release_time, SYSDATETIME())
         WHERE rectify_id = @rectify_id;
    ELSE IF @status IN (N'待整改', N'整改中', N'待复查', N'复查不通过', N'逾期未改')
        UPDATE dbo.rectification
           SET restrict_flag = 'Y',
               release_time = NULL
         WHERE rectify_id = @rectify_id;
END;
GO
