/*
社区居家养老智慧服务平台
成员1：复杂SQL查询

查询目的：
综合老人档案、最新能力评估和照护计划，形成老人照护跟进情况清单。

本查询使用：
1. 多表连接（LEFT JOIN）
2. 公共表表达式（CTE）
3. ROW_NUMBER() 窗口函数，筛选每位老人最新一次评估
4. GROUP BY 分组统计照护计划
5. CASE WHEN 判断评估有效期和照护跟进建议

执行前提：
已在 Member1_Standalone_Test 数据库中创建五张表并插入测试数据。
*/

-- 一、综合查询：老人能力评估与照护计划跟进情况
;WITH LatestAssessment AS
(
    -- 使用窗口函数，为每位老人按评估日期从新到旧排序
    SELECT
        a.assessment_id,
        a.elder_id,
        a.scale_type,
        a.score,
        a.ability_level,
        a.assessment_date,
        a.valid_until,
        ROW_NUMBER() OVER
        (
            PARTITION BY a.elder_id
            ORDER BY a.assessment_date DESC, a.assessment_id DESC
        ) AS rn
    FROM dbo.ability_assessment AS a
),
PlanStatistics AS
(
    -- 按老人统计照护计划总数和当前生效计划数
    SELECT
        p.elder_id,
        COUNT(*) AS total_plan_count,
        SUM
        (
            CASE
                WHEN p.plan_status = N'生效'
                 AND p.start_date <= CONVERT(date, GETDATE())
                 AND p.end_date >= CONVERT(date, GETDATE())
                THEN 1 ELSE 0
            END
        ) AS current_active_plan_count,
        SUM(CASE WHEN p.plan_status = N'暂停' THEN 1 ELSE 0 END) AS paused_plan_count,
        SUM(CASE WHEN p.plan_status = N'待生效' THEN 1 ELSE 0 END) AS pending_plan_count
    FROM dbo.care_plan AS p
    GROUP BY p.elder_id
)
SELECT
    e.elder_id AS 老人编号,
    e.elder_name AS 老人姓名,
    e.community_name AS 所属社区,
    e.archive_status AS 档案状态,
    CASE WHEN e.is_living_alone = 1 THEN N'是' ELSE N'否' END AS 是否独居,
    CASE WHEN e.is_disabled = 1 THEN N'是' ELSE N'否' END AS 是否失能,
    la.ability_level AS 最新能力等级,
    la.score AS 最新评估得分,
    la.assessment_date AS 最近评估日期,
    la.valid_until AS 评估有效期至,
    CASE
        WHEN la.assessment_id IS NULL THEN N'未评估'
        WHEN la.valid_until < CONVERT(date, GETDATE()) THEN N'已过期'
        ELSE N'有效'
    END AS 评估状态,
    ISNULL(ps.total_plan_count, 0) AS 照护计划总数,
    ISNULL(ps.current_active_plan_count, 0) AS 当前生效计划数,
    ISNULL(ps.paused_plan_count, 0) AS 暂停计划数,
    ISNULL(ps.pending_plan_count, 0) AS 待生效计划数,
    CASE
        WHEN e.archive_status <> N'正常'
            THEN N'档案状态非正常，建议核实'
        WHEN la.assessment_id IS NULL
            THEN N'尚未进行能力评估，建议安排评估'
        WHEN la.valid_until < CONVERT(date, GETDATE())
            THEN N'能力评估已过期，建议重新评估'
        WHEN e.is_living_alone = 1
         AND e.is_disabled = 1
         AND ISNULL(ps.current_active_plan_count, 0) = 0
            THEN N'独居且失能，暂无生效计划，建议优先关注'
        WHEN la.ability_level IN (N'中度失能', N'重度失能')
         AND ISNULL(ps.current_active_plan_count, 0) = 0
            THEN N'失能程度较高且暂无生效计划，建议优先安排'
        WHEN ISNULL(ps.current_active_plan_count, 0) = 0
            THEN N'暂无当前生效照护计划，建议核实'
        ELSE N'正常跟进'
    END AS 照护跟进建议
FROM dbo.elder_profile AS e
LEFT JOIN LatestAssessment AS la
    ON la.elder_id = e.elder_id
   AND la.rn = 1
LEFT JOIN PlanStatistics AS ps
    ON ps.elder_id = e.elder_id
ORDER BY
    CASE
        WHEN e.archive_status <> N'正常' THEN 1
        WHEN la.assessment_id IS NULL THEN 2
        WHEN la.valid_until < CONVERT(date, GETDATE()) THEN 3
        WHEN e.is_living_alone = 1
         AND e.is_disabled = 1
         AND ISNULL(ps.current_active_plan_count, 0) = 0 THEN 4
        WHEN la.ability_level IN (N'中度失能', N'重度失能')
         AND ISNULL(ps.current_active_plan_count, 0) = 0 THEN 5
        WHEN ISNULL(ps.current_active_plan_count, 0) = 0 THEN 6
        ELSE 7
    END,
    e.elder_id;
GO

-- 二、检查查询结果数量
-- 由于使用 LEFT JOIN，所有老人档案都应出现在结果中
SELECT COUNT(*) AS 查询返回老人数量
FROM dbo.elder_profile;
GO
