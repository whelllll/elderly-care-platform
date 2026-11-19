/*
社区居家养老智慧服务平台
成员1：三个视图创建与测试脚本

执行前提：
1. 已选择 Member1_Standalone_Test 数据库
2. 已成功执行 01_member1_tables.sql
3. 已成功执行 03_member1_test_data.sql

本脚本创建三个视图：
1. vw_elder_latest_assessment：老人最新一次能力评估及有效期
2. vw_elder_care_plan_summary：每位老人的照护计划数量统计
3. vw_active_care_plan：当前处于生效状态且在有效日期范围内的照护计划
*/

-- 如果顶部数据库下拉框选择正确，可以直接执行本脚本
-- USE [Member1_Standalone_Test];
-- GO

-- 一、老人最新一次能力评估视图
-- 每位老人只显示评估日期最新的一条记录；没有评估记录的老人也会显示
CREATE OR ALTER VIEW dbo.vw_elder_latest_assessment
AS
WITH RankedAssessment AS
(
    SELECT
        a.assessment_id,
        a.elder_id,
        a.scale_type,
        a.score,
        a.ability_level,
        a.assessor_name,
        a.assessment_date,
        a.valid_until,
        ROW_NUMBER() OVER
        (
            PARTITION BY a.elder_id
            ORDER BY a.assessment_date DESC, a.assessment_id DESC
        ) AS rn
    FROM dbo.ability_assessment AS a
)
SELECT
    e.elder_id,
    e.elder_name,
    e.id_card_no,
    e.community_name,
    e.archive_status,
    a.assessment_id,
    a.scale_type,
    a.score,
    a.ability_level,
    a.assessor_name,
    a.assessment_date,
    a.valid_until,
    CASE
        WHEN a.assessment_id IS NULL THEN N'未评估'
        WHEN a.valid_until < CONVERT(date, GETDATE()) THEN N'已过期'
        ELSE N'有效'
    END AS assessment_validity
FROM dbo.elder_profile AS e
LEFT JOIN RankedAssessment AS a
    ON a.elder_id = e.elder_id
   AND a.rn = 1;
GO

-- 二、老人照护计划统计视图
-- 统计每位老人拥有的照护计划总数，以及不同状态的计划数量
-- 使用 LEFT JOIN，确保没有照护计划的老人也会显示
CREATE OR ALTER VIEW dbo.vw_elder_care_plan_summary
AS
SELECT
    e.elder_id,
    e.elder_name,
    e.archive_status,
    COUNT(p.plan_id) AS total_plan_count,
    SUM(CASE WHEN p.plan_status = N'生效' THEN 1 ELSE 0 END) AS active_plan_count,
    SUM(CASE WHEN p.plan_status = N'暂停' THEN 1 ELSE 0 END) AS paused_plan_count,
    SUM(CASE WHEN p.plan_status = N'待生效' THEN 1 ELSE 0 END) AS pending_plan_count,
    SUM(CASE WHEN p.plan_status = N'已结束' THEN 1 ELSE 0 END) AS ended_plan_count,
    SUM(CASE WHEN p.plan_status = N'已取消' THEN 1 ELSE 0 END) AS cancelled_plan_count,
    MAX(p.start_date) AS latest_plan_start_date
FROM dbo.elder_profile AS e
LEFT JOIN dbo.care_plan AS p
    ON p.elder_id = e.elder_id
GROUP BY
    e.elder_id,
    e.elder_name,
    e.archive_status;
GO

-- 三、当前生效照护计划视图
-- 只显示计划状态为“生效”，且当前日期处于计划起止日期之间的记录
CREATE OR ALTER VIEW dbo.vw_active_care_plan
AS
SELECT
    p.plan_id,
    e.elder_id,
    e.elder_name,
    e.community_name,
    p.service_package_name,
    p.service_frequency,
    p.start_date,
    p.end_date,
    p.responsible_caregiver_id,
    p.plan_status
FROM dbo.care_plan AS p
INNER JOIN dbo.elder_profile AS e
    ON e.elder_id = p.elder_id
WHERE p.plan_status = N'生效'
  AND p.start_date <= CONVERT(date, GETDATE())
  AND p.end_date >= CONVERT(date, GETDATE());
GO

-- 四、检查三个视图是否创建成功
SELECT
    name AS view_name
FROM sys.views
WHERE schema_id = SCHEMA_ID(N'dbo')
  AND name IN
  (
      N'vw_elder_latest_assessment',
      N'vw_elder_care_plan_summary',
      N'vw_active_care_plan'
  )
ORDER BY name;
GO

-- 五、分别查询三个视图，检查返回结果
SELECT * FROM dbo.vw_elder_latest_assessment
ORDER BY elder_id;
GO

SELECT * FROM dbo.vw_elder_care_plan_summary
ORDER BY elder_id;
GO

SELECT * FROM dbo.vw_active_care_plan
ORDER BY elder_id, plan_id;
GO
