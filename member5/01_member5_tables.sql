-- =============================================================
-- 成员5 补贴核算与质量监管  |  01 建表与索引
-- 目标数据库：Microsoft SQL Server 2019（兼容 2016+）
-- 依赖：无（跨模块外键在 02_member5_foreign_keys.sql 中统一挂载）
-- 说明：本文件只创建成员5自管的 6 张表与索引，可单独执行。
-- =============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;

IF DB_ID() <= 4 THROW 52000, N'请先选择用户数据库再执行本脚本。', 1;

BEGIN TRY
    BEGIN TRAN;

    -- ---------------------------------------------------------
    -- 1. 补贴政策表
    -- ---------------------------------------------------------
    IF OBJECT_ID(N'dbo.subsidy_policy', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.subsidy_policy (
            policy_id        INT IDENTITY(1,1) NOT NULL,
            policy_name      NVARCHAR(100) NOT NULL,
            district_code    NVARCHAR(12)  NOT NULL,
            target_category  NVARCHAR(10)  NOT NULL,
            service_item_id  INT           NOT NULL,
            care_level       NVARCHAR(10)  NULL,
            subsidy_mode     NVARCHAR(10)  NOT NULL,
            subsidy_standard DECIMAL(10,2) NOT NULL,
            subsidy_ratio    DECIMAL(5,4)  NULL,
            per_capita_limit DECIMAL(10,2) NULL,
            settle_cycle     CHAR(6)       NOT NULL,
            effective_date   DATE          NOT NULL,
            expire_date      DATE          NULL,
            doc_no           NVARCHAR(50)  NULL,
            policy_status    NVARCHAR(8)   NOT NULL
                CONSTRAINT DF_M5_policy_status DEFAULT N'生效',
            create_time      DATETIME2(0)  NOT NULL
                CONSTRAINT DF_M5_policy_create DEFAULT SYSDATETIME(),
            remark           NVARCHAR(200) NULL,
            CONSTRAINT PK_M5_subsidy_policy PRIMARY KEY CLUSTERED (policy_id),
            CONSTRAINT CK_M5_policy_target CHECK
                (target_category IN (N'低保', N'失能', N'高龄', N'重点优抚', N'普通')),
            CONSTRAINT CK_M5_policy_care_level CHECK
                (care_level IS NULL OR care_level IN (N'能力完好', N'轻度失能', N'中度失能', N'重度失能')),
            -- 补贴方式与成员2 service_item.charge_unit 对齐：
            --   charge_unit = N'次'   → 按次定额 / 按比例
            --   charge_unit = N'小时' → 按工时（标准×有效工时）/ 按比例
            -- 跨表匹配无法用 CHECK 表达，由 usp_M5_CreateApplication 在写入申报时校验。
            CONSTRAINT CK_M5_policy_mode CHECK
                (subsidy_mode IN (N'按次定额', N'按工时', N'按比例', N'按月定额')),
            CONSTRAINT CK_M5_policy_standard CHECK (subsidy_standard > 0),
            CONSTRAINT CK_M5_policy_ratio CHECK
                (subsidy_ratio IS NULL OR (subsidy_ratio > 0 AND subsidy_ratio <= 1)),
            CONSTRAINT CK_M5_policy_ratio_required CHECK
                (subsidy_mode <> N'按比例' OR subsidy_ratio IS NOT NULL),
            CONSTRAINT CK_M5_policy_no_ratio CHECK
                (subsidy_mode = N'按比例' OR subsidy_ratio IS NULL),
            CONSTRAINT CK_M5_policy_limit CHECK
                (per_capita_limit IS NULL OR per_capita_limit >= 0),
            CONSTRAINT CK_M5_policy_cycle CHECK
                (settle_cycle IN (N'月', N'季', N'半年', N'年')),
            CONSTRAINT CK_M5_policy_date CHECK
                (expire_date IS NULL OR expire_date >= effective_date),
            CONSTRAINT CK_M5_policy_status CHECK
                (policy_status IN (N'草稿', N'生效', N'停用'))
        );

        CREATE UNIQUE INDEX UX_M5_policy_doc_no
            ON dbo.subsidy_policy (doc_no) WHERE doc_no IS NOT NULL;
        CREATE INDEX IX_M5_policy_match
            ON dbo.subsidy_policy (district_code, policy_status, effective_date)
            INCLUDE (service_item_id, subsidy_mode, subsidy_standard, subsidy_ratio, expire_date);
        CREATE INDEX IX_M5_policy_item
            ON dbo.subsidy_policy (service_item_id);
    END;

    -- ---------------------------------------------------------
    -- 2. 补贴申报表
    -- ---------------------------------------------------------
    IF OBJECT_ID(N'dbo.subsidy_application', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.subsidy_application (
            application_id    INT IDENTITY(1,1) NOT NULL,
            elder_id          INT           NOT NULL,
            policy_id         INT           NOT NULL,
            settle_cycle      CHAR(7)       NOT NULL,
            application_amount DECIMAL(10,2) NOT NULL,
            self_pay_amount   DECIMAL(10,2) NOT NULL
                CONSTRAINT DF_M5_app_selfpay DEFAULT 0,
            order_count       INT           NOT NULL
                CONSTRAINT DF_M5_app_ordercnt DEFAULT 0,
            total_hours       DECIMAL(8,2)  NOT NULL
                CONSTRAINT DF_M5_app_hours DEFAULT 0,
            apply_type        NVARCHAR(8)   NOT NULL
                CONSTRAINT DF_M5_app_type DEFAULT N'系统汇总',
            audit_status      NVARCHAR(12)  NOT NULL
                CONSTRAINT DF_M5_app_audit DEFAULT N'待社区初审',
            current_auditor_id INT          NULL,
            audit_finish_time DATETIME2(0)  NULL,
            pay_status        NVARCHAR(8)   NOT NULL
                CONSTRAINT DF_M5_app_pay DEFAULT N'未拨付',
            pay_time          DATETIME2(0)  NULL,
            pay_voucher_no    NVARCHAR(40)  NULL,
            create_by         NVARCHAR(20)  NOT NULL,
            create_time       DATETIME2(0)  NOT NULL
                CONSTRAINT DF_M5_app_create DEFAULT SYSDATETIME(),
            remark            NVARCHAR(200) NULL,
            CONSTRAINT PK_M5_subsidy_application PRIMARY KEY CLUSTERED (application_id),
            CONSTRAINT FK_M5_app_policy FOREIGN KEY (policy_id)
                REFERENCES dbo.subsidy_policy (policy_id)
                ON DELETE NO ACTION ON UPDATE NO ACTION,
            CONSTRAINT UQ_M5_app_once UNIQUE (elder_id, policy_id, settle_cycle),
            CONSTRAINT CK_M5_app_amount CHECK (application_amount >= 0),
            CONSTRAINT CK_M5_app_selfpay CHECK (self_pay_amount >= 0),
            CONSTRAINT CK_M5_app_ordercnt CHECK (order_count >= 0),
            CONSTRAINT CK_M5_app_hours CHECK (total_hours >= 0),
            CONSTRAINT CK_M5_app_type CHECK (apply_type IN (N'系统汇总', N'手工补报')),
            CONSTRAINT CK_M5_app_audit CHECK (audit_status IN
                (N'待社区初审', N'街道复审中', N'民政终审中', N'审核通过', N'审核驳回', N'退回补正')),
            CONSTRAINT CK_M5_app_pay CHECK (pay_status IN (N'未拨付', N'拨付中', N'已拨付', N'拨付失败')),
            CONSTRAINT CK_M5_app_cycle CHECK (
                LEN(settle_cycle) = 7
                AND settle_cycle LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]'
                AND CONVERT(TINYINT, RIGHT(settle_cycle, 2)) BETWEEN 1 AND 12),
            CONSTRAINT CK_M5_app_pay_time CHECK
                (pay_status <> N'已拨付' OR pay_time IS NOT NULL),
            CONSTRAINT CK_M5_app_audit_time CHECK
                (audit_status NOT IN (N'审核通过', N'审核驳回') OR audit_finish_time IS NOT NULL)
        );

        CREATE UNIQUE INDEX UX_M5_app_voucher
            ON dbo.subsidy_application (pay_voucher_no) WHERE pay_voucher_no IS NOT NULL;
        CREATE INDEX IX_M5_app_cycle_status
            ON dbo.subsidy_application (settle_cycle, audit_status, pay_status)
            INCLUDE (elder_id, policy_id, application_amount);
        CREATE INDEX IX_M5_app_elder
            ON dbo.subsidy_application (elder_id, settle_cycle);
    END;

    -- ---------------------------------------------------------
    -- 3. 申报订单明细表
    -- ---------------------------------------------------------
    IF OBJECT_ID(N'dbo.subsidy_application_item', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.subsidy_application_item (
            item_id         INT IDENTITY(1,1) NOT NULL,
            application_id  INT           NOT NULL,
            order_id        INT           NOT NULL,
            work_id         INT           NULL,
            service_amount  DECIMAL(10,2) NOT NULL,
            subsidy_amount  DECIMAL(10,2) NOT NULL,
            self_pay_amount DECIMAL(10,2) NOT NULL
                CONSTRAINT DF_M5_item_selfpay DEFAULT 0,
            valid_hours     DECIMAL(6,2)  NULL,
            verify_result   NVARCHAR(8)   NOT NULL
                CONSTRAINT DF_M5_item_verify DEFAULT N'通过',
            remark          NVARCHAR(200) NULL,
            CONSTRAINT PK_M5_subsidy_application_item PRIMARY KEY CLUSTERED (item_id),
            CONSTRAINT FK_M5_item_application FOREIGN KEY (application_id)
                REFERENCES dbo.subsidy_application (application_id)
                ON DELETE NO ACTION ON UPDATE NO ACTION,
            CONSTRAINT UQ_M5_item_order UNIQUE (order_id),
            CONSTRAINT CK_M5_item_service CHECK (service_amount >= 0),
            CONSTRAINT CK_M5_item_subsidy CHECK (subsidy_amount >= 0),
            CONSTRAINT CK_M5_item_selfpay CHECK (self_pay_amount >= 0),
            CONSTRAINT CK_M5_item_hours CHECK (valid_hours IS NULL OR valid_hours >= 0),
            CONSTRAINT CK_M5_item_verify CHECK
                (verify_result IN (N'通过', N'待核', N'工时缺失', N'金额超限')),
            CONSTRAINT CK_M5_item_reconcile CHECK
                (subsidy_amount + self_pay_amount <= service_amount)
        );

        CREATE INDEX IX_M5_item_application
            ON dbo.subsidy_application_item (application_id)
            INCLUDE (order_id, service_amount, subsidy_amount);
        CREATE INDEX IX_M5_item_work
            ON dbo.subsidy_application_item (work_id)
            WHERE work_id IS NOT NULL;
    END;

    -- ---------------------------------------------------------
    -- 4. 审核记录表（只增不改的留痕表）
    -- ---------------------------------------------------------
    IF OBJECT_ID(N'dbo.subsidy_audit_log', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.subsidy_audit_log (
            audit_id       INT IDENTITY(1,1) NOT NULL,
            application_id INT           NOT NULL,
            audit_node     NVARCHAR(10)  NOT NULL,
            auditor_id     INT           NOT NULL,
            auditor_org    NVARCHAR(60)  NOT NULL,
            audit_action   NVARCHAR(10)  NOT NULL,
            audit_opinion  NVARCHAR(200) NULL,
            before_status  NVARCHAR(12)  NULL,
            after_status   NVARCHAR(12)  NOT NULL,
            audit_time     DATETIME2(0)  NOT NULL
                CONSTRAINT DF_M5_audit_time DEFAULT SYSDATETIME(),
            attach_url     NVARCHAR(200) NULL,
            client_ip      VARCHAR(45)   NULL,
            CONSTRAINT PK_M5_subsidy_audit_log PRIMARY KEY CLUSTERED (audit_id),
            CONSTRAINT FK_M5_audit_application FOREIGN KEY (application_id)
                REFERENCES dbo.subsidy_application (application_id)
                ON DELETE NO ACTION ON UPDATE NO ACTION,
            CONSTRAINT CK_M5_audit_node CHECK
                (audit_node IN (N'社区初审', N'街道复审', N'民政终审')),
            CONSTRAINT CK_M5_audit_action CHECK
                (audit_action IN (N'提交', N'通过', N'驳回', N'退回补正')),
            CONSTRAINT CK_M5_audit_opinion CHECK
                (audit_action <> N'驳回' OR audit_opinion IS NOT NULL),
            CONSTRAINT CK_M5_audit_status CHECK (after_status IN
                (N'待社区初审', N'街道复审中', N'民政终审中', N'审核通过', N'审核驳回', N'退回补正'))
        );

        CREATE INDEX IX_M5_audit_app
            ON dbo.subsidy_audit_log (application_id, audit_time)
            INCLUDE (audit_node, audit_action, auditor_id);
    END;

    -- ---------------------------------------------------------
    -- 5. 质量抽查表
    -- ---------------------------------------------------------
    IF OBJECT_ID(N'dbo.quality_inspection', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.quality_inspection (
            inspection_id   INT IDENTITY(1,1) NOT NULL,
            object_type     NVARCHAR(6)   NOT NULL,
            order_id        INT           NULL,
            caregiver_id    INT           NULL,
            inspect_method  NVARCHAR(10)  NOT NULL,
            inspect_source  NVARCHAR(10)  NULL,
            inspect_time    DATETIME2(0)  NOT NULL,
            inspector_id    INT           NOT NULL,
            inspector_org   NVARCHAR(60)  NOT NULL,
            score           DECIMAL(4,1)  NULL,
            score_level     AS (CASE
                    WHEN score IS NULL THEN NULL
                    WHEN score >= 90 THEN N'优秀'
                    WHEN score >= 75 THEN N'良好'
                    WHEN score >= 60 THEN N'合格'
                    ELSE N'不合格' END) PERSISTED,
            authenticity    NVARCHAR(8)   NULL,
            problem_tags    NVARCHAR(100) NULL,
            inspect_result  NVARCHAR(8)   NOT NULL,
            rectify_flag    CHAR(1)       NOT NULL
                CONSTRAINT DF_M5_insp_rectify DEFAULT 'N',
            rectify_deadline DATE         NULL,
            inspect_status  NVARCHAR(8)   NOT NULL
                CONSTRAINT DF_M5_insp_status DEFAULT N'待核查',
            remark          NVARCHAR(200) NULL,
            CONSTRAINT PK_M5_quality_inspection PRIMARY KEY CLUSTERED (inspection_id),
            CONSTRAINT CK_M5_insp_object CHECK (object_type IN (N'订单', N'护工')),
            CONSTRAINT CK_M5_insp_object_exclusive CHECK (
                (object_type = N'订单' AND order_id IS NOT NULL AND caregiver_id IS NULL)
                OR (object_type = N'护工' AND caregiver_id IS NOT NULL AND order_id IS NULL)),
            CONSTRAINT CK_M5_insp_method CHECK
                (inspect_method IN (N'电话回访', N'上门核查', N'系统稽核')),
            CONSTRAINT CK_M5_insp_source CHECK
                (inspect_source IS NULL OR inspect_source IN (N'系统随机', N'投诉转办', N'专项整治')),
            CONSTRAINT CK_M5_insp_score CHECK (score IS NULL OR (score >= 0 AND score <= 100)),
            CONSTRAINT CK_M5_insp_auth CHECK
                (authenticity IS NULL OR authenticity IN (N'真实', N'部分真实', N'不真实')),
            CONSTRAINT CK_M5_insp_result CHECK
                (inspect_result IN (N'合格', N'基本合格', N'不合格')),
            CONSTRAINT CK_M5_insp_rectify CHECK (rectify_flag IN ('Y', 'N')),
            CONSTRAINT CK_M5_insp_deadline CHECK
                (rectify_flag <> 'Y' OR rectify_deadline IS NOT NULL),
            CONSTRAINT CK_M5_insp_status CHECK
                (inspect_status IN (N'待核查', N'已完成', N'已作废'))
        );

        CREATE INDEX IX_M5_insp_order ON dbo.quality_inspection (order_id) WHERE order_id IS NOT NULL;
        CREATE INDEX IX_M5_insp_caregiver ON dbo.quality_inspection (caregiver_id) WHERE caregiver_id IS NOT NULL;
        CREATE INDEX IX_M5_insp_time ON dbo.quality_inspection (inspect_time, inspect_result);
    END;

    -- ---------------------------------------------------------
    -- 6. 整改记录表
    -- ---------------------------------------------------------
    IF OBJECT_ID(N'dbo.rectification', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.rectification (
            rectify_id      INT IDENTITY(1,1) NOT NULL,
            inspection_id   INT           NOT NULL,
            caregiver_id    INT           NULL,
            org_id          INT           NOT NULL,
            -- 整改对象级别：护工级（限制该护工）/ 机构级（限制该机构下全部护工）
            rectify_scope   NVARCHAR(4)   NOT NULL
                CONSTRAINT DF_M5_rect_scope DEFAULT N'护工',
            problem_desc    NVARCHAR(200) NOT NULL,
            rectify_requirement NVARCHAR(200) NOT NULL,
            rectify_deadline DATE         NOT NULL,
            rectify_status  NVARCHAR(10)  NOT NULL
                CONSTRAINT DF_M5_rect_status DEFAULT N'待整改',
            submit_time     DATETIME2(0)  NULL,
            review_time     DATETIME2(0)  NULL,
            reviewer_id     INT           NULL,
            review_result   NVARCHAR(8)   NULL,
            restrict_flag   CHAR(1)       NOT NULL
                CONSTRAINT DF_M5_rect_restrict DEFAULT 'N',
            release_time    DATETIME2(0)  NULL,
            remark          NVARCHAR(200) NULL,
            CONSTRAINT PK_M5_rectification PRIMARY KEY CLUSTERED (rectify_id),
            CONSTRAINT FK_M5_rect_inspection FOREIGN KEY (inspection_id)
                REFERENCES dbo.quality_inspection (inspection_id)
                ON DELETE NO ACTION ON UPDATE NO ACTION,
            CONSTRAINT CK_M5_rect_status CHECK (rectify_status IN
                (N'待整改', N'整改中', N'待复查', N'复查通过', N'复查不通过', N'逾期未改')),
            CONSTRAINT CK_M5_rect_result CHECK
                (review_result IS NULL OR review_result IN (N'通过', N'不通过', N'部分通过')),
            CONSTRAINT CK_M5_rect_restrict CHECK (restrict_flag IN ('Y', 'N')),
            CONSTRAINT CK_M5_rect_scope CHECK (rectify_scope IN (N'护工', N'机构')),
            -- 机构级整改不挂具体护工；护工级整改必须指明护工，两者互斥
            CONSTRAINT CK_M5_rect_scope_target CHECK (
                (rectify_scope = N'护工' AND caregiver_id IS NOT NULL)
                OR (rectify_scope = N'机构' AND caregiver_id IS NULL)),
            CONSTRAINT CK_M5_rect_pass CHECK
                (rectify_status <> N'复查通过'
                 OR (review_result = N'通过' AND review_time IS NOT NULL)),
            CONSTRAINT CK_M5_rect_release CHECK
                (release_time IS NULL OR restrict_flag = 'N'),
            CONSTRAINT CK_M5_rect_submit CHECK
                (rectify_status IN (N'待整改', N'整改中', N'逾期未改') OR submit_time IS NOT NULL)
        );

        CREATE INDEX IX_M5_rect_caregiver
            ON dbo.rectification (caregiver_id, restrict_flag, rectify_status)
            WHERE caregiver_id IS NOT NULL;
        CREATE INDEX IX_M5_rect_org
            ON dbo.rectification (org_id, rectify_status, rectify_deadline);
    END;

    -- ---------------------------------------------------------
    -- 6.x 兼容已建库（旧版 rectification 为 15 字段）
    --     补 rectify_scope 列与约束、补限制接单索引，可重复执行
    -- ---------------------------------------------------------
    IF COL_LENGTH(N'dbo.rectification', N'rectify_scope') IS NULL
        ALTER TABLE dbo.rectification
            ADD rectify_scope NVARCHAR(4) NOT NULL
                CONSTRAINT DF_M5_rect_scope DEFAULT N'护工';

    IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_M5_rect_scope')
        ALTER TABLE dbo.rectification WITH CHECK
            ADD CONSTRAINT CK_M5_rect_scope CHECK (rectify_scope IN (N'护工', N'机构'));

    IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_M5_rect_scope_target')
    BEGIN
        -- 历史数据：未挂具体护工的整改视为机构级
        UPDATE dbo.rectification SET rectify_scope = N'机构' WHERE caregiver_id IS NULL;
        ALTER TABLE dbo.rectification WITH CHECK
            ADD CONSTRAINT CK_M5_rect_scope_target CHECK (
                (rectify_scope = N'护工' AND caregiver_id IS NOT NULL)
                OR (rectify_scope = N'机构' AND caregiver_id IS NULL));
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE name = N'IX_M5_rect_blocked'
                     AND object_id = OBJECT_ID(N'dbo.rectification'))
        CREATE INDEX IX_M5_rect_blocked
            ON dbo.rectification (rectify_scope, org_id, caregiver_id, rectify_deadline)
            WHERE restrict_flag = 'Y';

    COMMIT;
    PRINT N'成员5：6 张表与索引已就绪。';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    THROW;
END CATCH;
