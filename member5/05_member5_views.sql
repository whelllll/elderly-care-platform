-- =============================================================
-- 成员5 补贴核算与质量监管  |  05 视图
-- 前置：01 建表完成；父表 service_order / service_item / elder_profile 已存在
--       （成员3 的 caregiver 若已建，本文件会自动把机构级限制扩散到护工）
-- 四个视图分别服务：监管人员看进度、审计追溯看明细、
--                   机构级限制清单、派单模块查限制接单
-- =============================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ① 申报与拨付进度视图：给街道/民政监管人员按周期看办理状态
CREATE OR ALTER VIEW dbo.vw_M5_ApplicationProgress
AS
SELECT a.application_id,
       a.settle_cycle,
       a.elder_id,
       ep.elder_name,
       ep.community_name,
       p.policy_id,
       p.policy_name,
       p.target_category,
       p.subsidy_mode,
       p.subsidy_ratio,
       a.order_count,
       a.total_hours,
       a.application_amount,
       a.self_pay_amount,
       a.audit_status,
       a.current_auditor_id,
       a.audit_finish_time,
       a.pay_status,
       a.pay_time,
       a.pay_voucher_no,
       a.create_by,
       a.create_time,
       (SELECT COUNT(*) FROM dbo.subsidy_application_item AS i
         WHERE i.application_id = a.application_id) AS item_count,
       (SELECT COUNT(*) FROM dbo.subsidy_application_item AS i
         WHERE i.application_id = a.application_id AND i.verify_result <> N'通过') AS abnormal_count,
       DATEDIFF(DAY, a.create_time, ISNULL(a.audit_finish_time, SYSDATETIME())) AS audit_days,
       CASE WHEN a.audit_status = N'审核通过' AND a.pay_status <> N'已拨付' THEN N'待拨付'
            WHEN a.audit_status IN (N'审核驳回', N'退回补正') THEN N'需补正'
            WHEN a.audit_status LIKE N'%中' OR a.audit_status = N'待社区初审' THEN N'审核中'
            ELSE N'已办结' END AS progress_stage
FROM dbo.subsidy_application AS a
JOIN dbo.subsidy_policy AS p ON p.policy_id = a.policy_id
LEFT JOIN dbo.elder_profile AS ep ON ep.elder_id = a.elder_id;
GO

-- ② 补贴明细追溯视图：一笔补贴能否落到订单与有效工时上
CREATE OR ALTER VIEW dbo.vw_M5_SubsidyTrace
AS
SELECT i.item_id,
       i.application_id,
       a.settle_cycle,
       a.elder_id,
       i.order_id,
       o.service_id,
       si.service_name,
       si.charge_unit,
       si.is_subsidizable,
       o.order_status,
       o.confirm_status,
       o.total_amount AS order_amount,
       i.service_amount,
       i.subsidy_amount,
       i.self_pay_amount,
       i.work_id,
       i.valid_hours,
       i.verify_result,
       p.policy_name,
       p.subsidy_mode,
       p.subsidy_standard,
       p.subsidy_ratio,
       CASE WHEN i.work_id IS NULL THEN N'缺工时记录'
            WHEN ISNULL(i.valid_hours, 0) <= 0 THEN N'有效工时为0'
            WHEN si.is_subsidizable = 0 THEN N'项目不可补贴'
            WHEN i.service_amount <> o.total_amount THEN N'金额与订单不符'
            ELSE N'可追溯' END AS trace_result,
       i.service_amount - (i.subsidy_amount + i.self_pay_amount) AS reconcile_gap,
       CASE WHEN p.subsidy_mode = N'按比例' AND i.service_amount > 0
            THEN CONVERT(DECIMAL(10,4), i.subsidy_amount / i.service_amount) END AS actual_ratio
FROM dbo.subsidy_application_item AS i
JOIN dbo.subsidy_application AS a ON a.application_id = i.application_id
JOIN dbo.subsidy_policy AS p ON p.policy_id = a.policy_id
JOIN dbo.service_order AS o ON o.order_id = i.order_id
JOIN dbo.service_item AS si ON si.service_id = o.service_id;
GO

-- ③ 机构级限制视图：机构存在未解除的机构级整改时，该机构整体禁止新派单
--    供成员2 派单/改派模块直接查询，也可作为管理端「机构黑名单」看板数据源
CREATE OR ALTER VIEW dbo.vw_M5_OrgBlocked
AS
SELECT r.org_id,
       COUNT(*)                    AS blocked_count,
       MIN(r.rectify_deadline)     AS earliest_deadline,
       MAX(r.rectify_deadline)     AS latest_deadline,
       MIN(r.rectify_id)           AS first_rectify_id,
       MAX(r.problem_desc)         AS latest_problem
FROM dbo.rectification AS r
WHERE r.restrict_flag = 'Y'
  AND r.rectify_scope  = N'机构'
  AND r.rectify_status <> N'复查通过'
GROUP BY r.org_id;
GO

-- ④ 限制接单护工视图：成员2 派单模块直接查询，命中任意一行即禁止分配新订单
--    先建「仅护工级」基础版，保证成员3 的 caregiver 未就绪时本文件仍可整体执行
CREATE OR ALTER VIEW dbo.vw_M5_CaregiverBlocked
AS
SELECT r.caregiver_id,
       COUNT(*)                AS blocked_count,
       MIN(r.rectify_deadline) AS earliest_deadline,
       MAX(r.rectify_deadline) AS latest_deadline,
       MAX(r.org_id)           AS org_id,
       MAX(r.problem_desc)     AS latest_problem,
       N'护工级'               AS block_level,
       MIN(r.rectify_id)       AS first_rectify_id
FROM dbo.rectification AS r
WHERE r.restrict_flag = 'Y'
  AND r.rectify_scope  = N'护工'
  AND r.caregiver_id IS NOT NULL
  AND r.rectify_status <> N'复查通过'
GROUP BY r.caregiver_id;
GO

-- ④' 成员3 的 caregiver 就绪后，升级为「护工级 + 机构级」合并视图：
--     机构级限制 → 该机构下全部护工都出现在结果集中（block_level = '机构级'）
IF OBJECT_ID(N'dbo.caregiver', N'U') IS NOT NULL
BEGIN
    EXEC sys.sp_executesql N'
CREATE OR ALTER VIEW dbo.vw_M5_CaregiverBlocked
AS
WITH blk AS (
    -- 护工级：整改直接挂在护工身上（org_id 取护工当前归属机构，
    --         避免 MAX(org_id) 聚合把同时受护工级+机构级限制的护工归错机构）
    SELECT r.caregiver_id,
           N''护工级''   AS block_level,
           r.rectify_id,
           c.org_id,
           r.rectify_deadline,
           r.problem_desc
    FROM dbo.rectification AS r
    JOIN dbo.caregiver AS c ON c.caregiver_id = r.caregiver_id
    WHERE r.restrict_flag = ''Y''
      AND r.rectify_scope  = N''护工''
      AND r.caregiver_id IS NOT NULL
      AND r.rectify_status <> N''复查通过''

    UNION ALL

    -- 机构级：机构受限则旗下护工一并受限（规则：机构被限制时全员禁新单）
    SELECT c.caregiver_id,
           N''机构级'',
           r.rectify_id,
           r.org_id,
           r.rectify_deadline,
           r.problem_desc
    FROM dbo.rectification AS r
    JOIN dbo.caregiver AS c ON c.org_id = r.org_id
    WHERE r.restrict_flag = ''Y''
      AND r.rectify_scope  = N''机构''
      AND r.rectify_status <> N''复查通过''
)
SELECT caregiver_id,
       COUNT(*)                AS blocked_count,
       MIN(rectify_deadline)   AS earliest_deadline,
       MAX(rectify_deadline)   AS latest_deadline,
       MAX(org_id)             AS org_id,
       MAX(problem_desc)       AS latest_problem,
       CASE WHEN COUNT(DISTINCT block_level) = 2 THEN N''护工+机构''
            ELSE MAX(block_level) END AS block_level,
       MIN(rectify_id)         AS first_rectify_id
FROM blk
GROUP BY caregiver_id;';
END
ELSE
    PRINT N'提示：成员3 的 dbo.caregiver 尚未创建，vw_M5_CaregiverBlocked 当前只覆盖护工级限制；'
        + N'caregiver 建好后重跑本文件即自动升级为「护工级 + 机构级」。';
GO
