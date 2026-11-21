-- =============================================================
-- 成员5 补贴核算与质量监管  |  04 复杂查询
-- 查询1：按周期审计补贴申报的可追溯性（7 张表关联）
-- 查询2：机构与护工的质量监管画像（4 张表关联 + 聚合 + 子查询）
-- =============================================================
SET NOCOUNT ON;
GO

/* -------------------------------------------------------------
   查询1  补贴申报追溯审计
   业务问题：某结算周期内，哪些申报单的补贴金额落不到“订单 + 有效工时”上，
             各级审核是否可以据此退回补正？
   关联：subsidy_application / subsidy_policy / subsidy_application_item
         / service_order / service_item / elder_profile / subsidy_audit_log
   ------------------------------------------------------------- */
-- 与 03 测试数据的账期口径保持一致（均为当月）
DECLARE @cycle CHAR(7) = CONVERT(CHAR(7), SYSDATETIME(), 120);

SELECT a.application_id,
       a.settle_cycle,
       ep.elder_name,
       ep.community_name,
       p.policy_name,
       p.subsidy_mode,
       COUNT(i.item_id)                                   AS item_count,
       SUM(CASE WHEN i.work_id IS NULL THEN 1 ELSE 0 END)  AS missing_work_count,
       SUM(CASE WHEN i.verify_result <> N'通过' THEN 1 ELSE 0 END) AS abnormal_count,
       SUM(CASE WHEN si.is_subsidizable = 0 THEN 1 ELSE 0 END)     AS nonsub_item_count,
       CAST(SUM(i.subsidy_amount) AS DECIMAL(12,2))        AS subsidy_total,
       CAST(SUM(i.self_pay_amount) AS DECIMAL(12,2))       AS selfpay_total,
       CAST(SUM(i.service_amount - i.subsidy_amount - i.self_pay_amount) AS DECIMAL(12,2)) AS reconcile_gap,
       CAST(100.0 * SUM(CASE WHEN i.work_id IS NOT NULL AND ISNULL(i.valid_hours, 0) > 0
                             THEN 1 ELSE 0 END) / NULLIF(COUNT(i.item_id), 0) AS DECIMAL(5,2)) AS trace_rate,
       (SELECT COUNT(*) FROM dbo.subsidy_audit_log AS l
         WHERE l.application_id = a.application_id)        AS audit_log_count,
       a.audit_status,
       a.pay_status,
       CASE WHEN SUM(CASE WHEN i.work_id IS NULL THEN 1 ELSE 0 END) > 0 THEN N'退回补正：缺工时'
            WHEN SUM(CASE WHEN i.verify_result <> N'通过' THEN 1 ELSE 0 END) > 0 THEN N'退回补正：明细异常'
            WHEN SUM(i.service_amount - i.subsidy_amount - i.self_pay_amount) <> 0 THEN N'退回补正：金额不平'
            ELSE N'可追溯，可提交终审' END                 AS audit_advice
FROM dbo.subsidy_application AS a
JOIN dbo.subsidy_policy      AS p  ON p.policy_id = a.policy_id
JOIN dbo.elder_profile       AS ep ON ep.elder_id = a.elder_id
JOIN dbo.subsidy_application_item AS i ON i.application_id = a.application_id
JOIN dbo.service_order       AS o  ON o.order_id = i.order_id
JOIN dbo.service_item        AS si ON si.service_id = o.service_id
WHERE a.settle_cycle = @cycle
GROUP BY a.application_id, a.settle_cycle, ep.elder_name, ep.community_name,
         p.policy_name, p.subsidy_mode, a.audit_status, a.pay_status
HAVING SUM(CASE WHEN i.work_id IS NULL OR i.verify_result <> N'通过' THEN 1 ELSE 0 END) > 0
    OR SUM(i.service_amount - i.subsidy_amount - i.self_pay_amount) <> 0
ORDER BY abnormal_count DESC, subsidy_total DESC;
GO

/* -------------------------------------------------------------
   查询2  机构与护工质量画像
   业务问题：哪些机构的抽查不合格率高、整改又拖期，需要重点监管？
   关联：quality_inspection / rectification / caregiver / service_org
   导出指标：抽查量、平均分、不合格率、需整改数、按期完成率、在限制接单人数
   ------------------------------------------------------------- */
SELECT so.org_id,
       so.org_name,
       COUNT(DISTINCT qi.inspection_id)                                  AS inspection_count,
       CAST(AVG(qi.score) AS DECIMAL(5,1))                               AS avg_score,
       SUM(CASE WHEN qi.inspect_result = N'不合格' THEN 1 ELSE 0 END)     AS unqualified_count,
       CAST(100.0 * SUM(CASE WHEN qi.inspect_result = N'不合格' THEN 1 ELSE 0 END)
            / NULLIF(COUNT(DISTINCT qi.inspection_id), 0) AS DECIMAL(5,2)) AS unqualified_rate,
       COUNT(DISTINCT r.rectify_id)                                      AS rectify_count,
       SUM(CASE WHEN r.rectify_status = N'复查通过'
                 AND r.review_time <= DATEADD(DAY, 1, CONVERT(DATETIME2(0), r.rectify_deadline))
                THEN 1 ELSE 0 END)                                       AS ontime_count,
       CAST(100.0 * SUM(CASE WHEN r.rectify_status = N'复查通过'
                              AND r.review_time <= DATEADD(DAY, 1, CONVERT(DATETIME2(0), r.rectify_deadline))
                             THEN 1 ELSE 0 END)
            / NULLIF(COUNT(DISTINCT r.rectify_id), 0) AS DECIMAL(5,2))    AS ontime_rate,
       COUNT(DISTINCT CASE WHEN r.restrict_flag = 'Y'
                            AND r.rectify_status <> N'复查通过' THEN r.caregiver_id END) AS blocked_caregivers,
       -- 机构级整改：一旦存在未解除的机构级整改，该机构下全员禁新单（派单模块据此拦截）
       SUM(CASE WHEN r.rectify_scope = N'机构' AND r.restrict_flag = 'Y'
                 AND r.rectify_status <> N'复查通过' THEN 1 ELSE 0 END)    AS org_block_records,
       CASE WHEN SUM(CASE WHEN r.rectify_scope = N'机构' AND r.restrict_flag = 'Y'
                           AND r.rectify_status <> N'复查通过' THEN 1 ELSE 0 END) > 0
            THEN N'机构受限' ELSE N'可正常派单' END                        AS dispatch_status,
       RANK() OVER (ORDER BY SUM(CASE WHEN qi.inspect_result = N'不合格' THEN 1 ELSE 0 END) DESC,
                             AVG(qi.score) ASC)                          AS risk_rank
FROM dbo.quality_inspection AS qi
JOIN dbo.rectification      AS r  ON r.inspection_id = qi.inspection_id
JOIN dbo.service_org        AS so ON so.org_id = r.org_id
LEFT JOIN dbo.caregiver     AS c  ON c.caregiver_id = r.caregiver_id
WHERE qi.inspect_time >= DATEADD(MONTH, -6, SYSDATETIME())
GROUP BY so.org_id, so.org_name
ORDER BY risk_rank;
GO
