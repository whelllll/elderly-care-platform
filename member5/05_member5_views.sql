-- =============================================================
-- 成员5 补贴核算与质量监管  |  05 视图
-- 前置：01 建表完成；父表 service_order / service_item / elder_profile / caregiver 已存在
-- 三个视图分别服务：监管人员看进度、审计追溯看明细、派单模块查限制接单
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

-- ③ 限制接单护工视图：成员2 派单模块直接查询，restrict_flag = 'Y' 即禁止分配新订单
CREATE OR ALTER VIEW dbo.vw_M5_CaregiverBlocked
AS
SELECT r.caregiver_id,
       COUNT(*) AS blocked_count,
       MIN(r.rectify_deadline) AS earliest_deadline,
       MAX(r.rectify_deadline) AS latest_deadline,
       MAX(r.org_id) AS org_id,
       MAX(r.problem_desc) AS latest_problem
FROM dbo.rectification AS r
WHERE r.restrict_flag = 'Y'
  AND r.caregiver_id IS NOT NULL
  AND r.rectify_status NOT IN (N'复查通过')
GROUP BY r.caregiver_id;
GO
