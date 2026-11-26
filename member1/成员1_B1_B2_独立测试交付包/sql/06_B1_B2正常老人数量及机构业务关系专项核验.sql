/*
========================================================
B1/B2专项核验：正常老人数量及机构业务关系
目标数据库：M1_B1_B2_Independent_Test
用途：验证成员4提出的04测试前置条件
全程只读，不修改任何数据
========================================================
*/

USE [M1_B1_B2_Independent_Test];
GO

SET NOCOUNT ON;

-- 一、统计老人档案

DECLARE @TotalElders INT;
DECLARE @NormalElders INT;
DECLARE @OriginalNormal INT;
DECLARE @NewElders INT;
DECLARE @NewNormal INT;
DECLARE @NewCommunity INT;
DECLARE @Cancelled INT;
DECLARE @Moved INT;

SELECT @TotalElders = COUNT(*) FROM dbo.elder_profile;

SELECT @NormalElders = COUNT(*)
FROM dbo.elder_profile
WHERE archive_status = N'正常';

SELECT @OriginalNormal = COUNT(*)
FROM dbo.elder_profile
WHERE elder_name NOT LIKE N'M3T2030阳光老人[0-9][0-9]'
  AND archive_status = N'正常';

SELECT @NewElders = COUNT(*)
FROM dbo.elder_profile
WHERE elder_name LIKE N'M3T2030阳光老人[0-9][0-9]';

SELECT @NewNormal = COUNT(*)
FROM dbo.elder_profile
WHERE elder_name LIKE N'M3T2030阳光老人[0-9][0-9]'
  AND archive_status = N'正常';

SELECT @NewCommunity = COUNT(*)
FROM dbo.elder_profile
WHERE elder_name LIKE N'M3T2030阳光老人[0-9][0-9]'
  AND community_name = N'阳光社区';

SELECT @Cancelled = COUNT(*)
FROM dbo.elder_profile
WHERE archive_status = N'注销';

SELECT @Moved = COUNT(*)
FROM dbo.elder_profile
WHERE archive_status = N'迁出';

-- 二、统计机构

DECLARE @BaseOrgID INT;
DECLARE @BaseOrgCount INT;
DECLARE @B1OrgCount INT;
DECLARE @B1OrgValid INT;

SELECT
    @BaseOrgID = MIN(org_id),
    @BaseOrgCount = COUNT(*)
FROM dbo.service_org
WHERE org_name = N'阳光社区养老服务中心'
  AND org_address = N'阳光社区服务街道1号'
  AND org_status = N'正常'
  AND service_area = N'阳光社区';

SELECT @B1OrgCount = COUNT(*)
FROM dbo.service_org
WHERE org_name LIKE N'M3T2030联调机构[0-9][0-9]';

SELECT @B1OrgValid = COUNT(*)
FROM dbo.service_org
WHERE org_name LIKE N'M3T2030联调机构[0-9][0-9]'
  AND org_status = N'正常'
  AND service_area = N'阳光社区';

-- 三、统计评估、计划和明细

DECLARE @Assessments INT;
DECLARE @Plans INT;
DECLARE @Items INT;
DECLARE @DifferentElders INT;
DECLARE @DifferentCaregivers INT;

SELECT @Assessments = COUNT(*)
FROM dbo.ability_assessment;

SELECT @Plans = COUNT(*)
FROM dbo.care_plan
WHERE service_package_name LIKE N'M3T2030照护方案-[0-9][0-9]';

SELECT @Items = COUNT(*)
FROM dbo.care_plan_item i
JOIN dbo.care_plan p ON p.plan_id = i.plan_id
WHERE p.service_package_name LIKE N'M3T2030照护方案-[0-9][0-9]';

SELECT @DifferentElders = COUNT(DISTINCT elder_id)
FROM dbo.care_plan
WHERE service_package_name LIKE N'M3T2030照护方案-[0-9][0-9]';

SELECT @DifferentCaregivers = COUNT(DISTINCT responsible_caregiver_id)
FROM dbo.care_plan
WHERE service_package_name LIKE N'M3T2030照护方案-[0-9][0-9]';

-- 四、检查计划与老人、机构的业务关系

DECLARE @ValidOrgRelations INT;

SELECT @ValidOrgRelations = COUNT(*)
FROM dbo.care_plan p
JOIN dbo.elder_profile e
    ON e.elder_id = p.elder_id
JOIN dbo.caregiver c
    ON c.caregiver_id = p.responsible_caregiver_id
WHERE p.service_package_name LIKE N'M3T2030照护方案-[0-9][0-9]'
  AND e.archive_status = N'正常'
  AND e.community_name = N'阳光社区'
  AND c.org_id = @BaseOrgID
  AND c.service_area = N'阳光社区'
  AND c.employment_status = N'在岗';

-- 五、检查评估关联

IF EXISTS
(
    SELECT p.elder_id
    FROM dbo.care_plan p
    LEFT JOIN dbo.ability_assessment a
        ON a.elder_id = p.elder_id
    WHERE p.service_package_name LIKE N'M3T2030照护方案-[0-9][0-9]'
    GROUP BY p.elder_id
    HAVING COUNT(a.assessment_id) <> 1
)
    THROW 53301, N'计划与能力评估关联不正确。', 1;

-- 六、检查计划明细数量

IF EXISTS
(
    SELECT p.plan_id
    FROM dbo.care_plan p
    LEFT JOIN dbo.care_plan_item i
        ON i.plan_id = p.plan_id
    WHERE p.service_package_name LIKE N'M3T2030照护方案-[0-9][0-9]'
    GROUP BY p.plan_id
    HAVING COUNT(i.plan_item_id) <> 1
)
    THROW 53302, N'计划明细关联数量不正确。', 1;

-- 七、检查核心数据是否符合预期

IF @TotalElders <> 36
 OR @NormalElders <> 34
 OR @OriginalNormal <> 18
 OR @NewElders <> 16
 OR @NewNormal <> 16
 OR @NewCommunity <> 16
 OR @Cancelled <> 1
 OR @Moved <> 1
    THROW 53303, N'老人档案数量或状态不符合预期。', 1;

IF @BaseOrgCount <> 1
 OR @B1OrgCount <> 15
 OR @B1OrgValid <> 15
    THROW 53304, N'机构数量、状态或服务区域不符合预期。', 1;

IF @Assessments <> 20
 OR @Plans <> 20
 OR @Items <> 20
 OR @DifferentElders <> 20
 OR @DifferentCaregivers <> 20
 OR @ValidOrgRelations <> 20
    THROW 53305, N'评估、计划、明细或机构业务关系不符合预期。', 1;

-- 八、输出核验结果

SELECT
    N'专项核验通过' AS 执行结果,
    DB_NAME() AS 当前数据库;

SELECT N'老人档案总数' AS 核验项目,
       @TotalElders AS 实际数量, 36 AS 预期数量
UNION ALL
SELECT N'正常老人总数', @NormalElders, 34
UNION ALL
SELECT N'原有正常老人', @OriginalNormal, 18
UNION ALL
SELECT N'新增正常老人', @NewNormal, 16
UNION ALL
SELECT N'原注销老人', @Cancelled, 1
UNION ALL
SELECT N'原迁出老人', @Moved, 1
UNION ALL
SELECT N'新增机构', @B1OrgCount, 15
UNION ALL
SELECT N'新增能力评估', @Assessments, 20
UNION ALL
SELECT N'新增照护计划', @Plans, 20
UNION ALL
SELECT N'新增计划明细', @Items, 20
UNION ALL
SELECT N'正确关联机构的计划', @ValidOrgRelations, 20;

-- 九、查看原有两位非正常状态老人
SELECT
    elder_id AS 老人编号,
    elder_name AS 老人姓名,
    archive_status AS 档案状态
FROM dbo.elder_profile
WHERE archive_status IN (N'注销', N'迁出')
ORDER BY elder_id;

GO