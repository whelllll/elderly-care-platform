/*
社区居家养老智慧服务平台
成员1：存储过程创建与测试脚本

存储过程名称：usp_GetElderCareOverview
功能：
根据输入的老人编号，查询该老人的档案信息、最新能力评估、
评估有效期、照护计划统计，以及该老人的照护计划明细。

输入参数：
@elder_id INT：老人编号

执行前提：
已在 Member1_Standalone_Test 数据库中创建五张表并插入测试数据。
*/

-- 一、创建或修改存储过程
CREATE OR ALTER PROCEDURE dbo.usp_GetElderCareOverview
    @elder_id INT
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. 检查老人编号是否存在
    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.elder_profile
        WHERE elder_id = @elder_id
    )
    BEGIN
        THROW 50001, N'未找到该老人档案，请检查老人编号。', 1;
    END;

    -- 2. 查询老人基本档案、最新评估和照护计划统计
    SELECT
        e.elder_id AS 老人编号,
        e.elder_name AS 老人姓名,
        e.id_card_no AS 身份证号,
        e.community_name AS 所属社区,
        e.address AS 居住地址,
        e.archive_status AS 档案状态,
        a.scale_type AS 最新评估量表,
        a.score AS 最新评估得分,
        a.ability_level AS 最新能力等级,
        a.assessment_date AS 最近评估日期,
        a.valid_until AS 评估有效期至,
        CASE
            WHEN a.assessment_id IS NULL THEN N'未评估'
            WHEN a.valid_until < CONVERT(date, GETDATE()) THEN N'已过期'
            ELSE N'有效'
        END AS 评估状态,
        ISNULL(p.total_plan_count, 0) AS 照护计划总数,
        ISNULL(p.active_plan_count, 0) AS 生效计划数,
        ISNULL(p.paused_plan_count, 0) AS 暂停计划数,
        ISNULL(p.pending_plan_count, 0) AS 待生效计划数
    FROM dbo.elder_profile AS e
    OUTER APPLY
    (
        -- 获取该老人最近一次能力评估
        SELECT TOP (1)
            aa.assessment_id,
            aa.scale_type,
            aa.score,
            aa.ability_level,
            aa.assessment_date,
            aa.valid_until
        FROM dbo.ability_assessment AS aa
        WHERE aa.elder_id = e.elder_id
        ORDER BY aa.assessment_date DESC, aa.assessment_id DESC
    ) AS a
    OUTER APPLY
    (
        -- 统计该老人的不同状态照护计划数量
        SELECT
            COUNT(*) AS total_plan_count,
            SUM(CASE WHEN cp.plan_status = N'生效' THEN 1 ELSE 0 END) AS active_plan_count,
            SUM(CASE WHEN cp.plan_status = N'暂停' THEN 1 ELSE 0 END) AS paused_plan_count,
            SUM(CASE WHEN cp.plan_status = N'待生效' THEN 1 ELSE 0 END) AS pending_plan_count
        FROM dbo.care_plan AS cp
        WHERE cp.elder_id = e.elder_id
    ) AS p
    WHERE e.elder_id = @elder_id;

    -- 3. 查询该老人的全部照护计划明细
    SELECT
        plan_id AS 计划编号,
        service_package_name AS 服务套餐名称,
        service_frequency AS 服务频次,
        start_date AS 开始日期,
        end_date AS 结束日期,
        responsible_caregiver_id AS 责任护工编号,
        plan_status AS 计划状态
    FROM dbo.care_plan
    WHERE elder_id = @elder_id
    ORDER BY start_date DESC, plan_id DESC;
END;
GO

-- 二、执行存储过程进行测试
-- 这里使用老人编号1作为测试对象
EXEC dbo.usp_GetElderCareOverview @elder_id = 1;
GO

-- 三、查看存储过程是否创建成功
SELECT
    name AS procedure_name,
    create_date AS create_time,
    modify_date AS modify_time
FROM sys.procedures
WHERE schema_id = SCHEMA_ID(N'dbo')
  AND name = N'usp_GetElderCareOverview';
GO

/*
其他测试方式：
1. 查询老人2：EXEC dbo.usp_GetElderCareOverview @elder_id = 2;
2. 查询没有照护计划的老人16：EXEC dbo.usp_GetElderCareOverview @elder_id = 16;
3. 测试不存在的老人编号：EXEC dbo.usp_GetElderCareOverview @elder_id = 999;
   第3种测试会提示“未找到该老人档案”，属于预期的参数检查结果。
*/
