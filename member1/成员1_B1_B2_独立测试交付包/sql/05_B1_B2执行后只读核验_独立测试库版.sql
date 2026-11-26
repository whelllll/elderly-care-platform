/* 归档修订说明：原始文件的目标库仍指向Codex_M1M5_Data_...，与本轮实际独立测试库不一致。
本归档版已将目标库门禁修正为 M1_B1_B2_Independent_Test，并显式 USE 该隔离测试库。
本脚本只读，不执行 INSERT、UPDATE 或 DELETE。 */

/*
B1+B2执行后只读核验脚本
用途：在B1、B2均成功执行后核验数量、业务键、评估/计划/明细关系。
本脚本不写入、不更新、不删除任何数据。
请在目标隔离测试数据库中执行。
*/
USE [M1_B1_B2_Independent_Test];
GO

SET NOCOUNT ON;
DECLARE @TargetDatabase sysname=N'M1_B1_B2_Independent_Test';
IF DB_NAME()<>@TargetDatabase
    THROW 53100,N'当前数据库与核验脚本目标数据库不一致，请先确认隔离测试库。',1;

DECLARE @B1 int=(SELECT COUNT(*) FROM dbo.service_org WHERE org_name LIKE N'M3T2030联调机构[0-9][0-9]');
DECLARE @B2Elder int=(SELECT COUNT(*) FROM dbo.elder_profile WHERE elder_name LIKE N'M3T2030阳光老人[0-9][0-9]');
DECLARE @Assess int=(SELECT COUNT(*) FROM dbo.ability_assessment a JOIN dbo.elder_profile e ON e.elder_id=a.elder_id WHERE e.id_card_no IN ('11010119420617016X','11010119430602001X','11010119500612011X','11010119580607006X') OR e.elder_name LIKE N'M3T2030阳光老人[0-9][0-9]');
DECLARE @Plans int=(SELECT COUNT(*) FROM dbo.care_plan WHERE service_package_name LIKE N'M3T2030照护方案-[0-9][0-9]');
DECLARE @Items int=(SELECT COUNT(*) FROM dbo.care_plan_item i JOIN dbo.care_plan p ON p.plan_id=i.plan_id WHERE p.service_package_name LIKE N'M3T2030照护方案-[0-9][0-9]');
DECLARE @PlanElders int=(SELECT COUNT(DISTINCT elder_id) FROM dbo.care_plan WHERE service_package_name LIKE N'M3T2030照护方案-[0-9][0-9]');
DECLARE @PlanCaregivers int=(SELECT COUNT(DISTINCT responsible_caregiver_id) FROM dbo.care_plan WHERE service_package_name LIKE N'M3T2030照护方案-[0-9][0-9]');

IF @B1<>15 THROW 53101,N'B1机构数量不是15。',1;
IF (SELECT COUNT(DISTINCT org_name) FROM dbo.service_org WHERE org_name LIKE N'M3T2030联调机构[0-9][0-9]')<>15
 OR (SELECT COUNT(DISTINCT org_address) FROM dbo.service_org WHERE org_name LIKE N'M3T2030联调机构[0-9][0-9]')<>15
    THROW 53116,N'B1机构名称或地址未保持唯一。',1;
IF (SELECT COUNT(*) FROM dbo.service_org)<>20 THROW 53102,N'机构总数不是20。',1;
IF EXISTS(SELECT 1 FROM dbo.service_org WHERE org_name LIKE N'M3T2030联调机构[0-9][0-9]' AND (org_status<>N'正常' OR service_area<>N'阳光社区'))
    THROW 53103,N'B1机构状态或服务区域不符合预期。',1;
IF @B2Elder<>16 THROW 53104,N'B2新增老人数量不是16。',1;
IF (SELECT COUNT(*) FROM dbo.elder_profile)<>36 THROW 53105,N'老人档案总数不是36。',1;
IF @Assess<>20 THROW 53106,N'本批20位老人对应的评估记录数量不是20。',1;
IF @Plans<>20 THROW 53107,N'本批照护计划数量不是20。',1;
IF @Items<>20 THROW 53108,N'本批照护计划明细数量不是20。',1;
IF @PlanElders<>20 THROW 53113,N'20份照护计划没有对应20位不同老人。',1;
IF @PlanCaregivers<>20 THROW 53114,N'20份照护计划没有对应20名不同责任护工。',1;
IF EXISTS(
    SELECT p.elder_id
    FROM dbo.care_plan p
    LEFT JOIN dbo.ability_assessment a ON a.elder_id=p.elder_id
    WHERE p.service_package_name LIKE N'M3T2030照护方案-[0-9][0-9]'
    GROUP BY p.elder_id
    HAVING COUNT(a.assessment_id)<>1
) THROW 53115,N'每位计划老人必须且只能对应一条本批能力评估。',1;
IF EXISTS(
    SELECT 1 FROM dbo.care_plan p
    WHERE p.service_package_name LIKE N'M3T2030照护方案-[0-9][0-9]'
      AND (p.service_frequency<>N'每月1次' OR p.start_date<>'20300101' OR p.end_date<>'20300131' OR p.plan_status<>N'待生效' OR p.responsible_caregiver_id IS NULL)
) THROW 53109,N'照护计划频次、日期、状态或责任护工不符合预期。',1;
IF EXISTS(
    SELECT p.plan_id
    FROM dbo.care_plan p
    LEFT JOIN dbo.care_plan_item i ON i.plan_id=p.plan_id
    WHERE p.service_package_name LIKE N'M3T2030照护方案-[0-9][0-9]'
    GROUP BY p.plan_id
    HAVING COUNT(i.plan_item_id)<>1
) THROW 53110,N'每份测试计划必须且只能关联一条服务明细。',1;
IF EXISTS(
    SELECT 1
    FROM dbo.care_plan p
    JOIN dbo.care_plan_item i ON i.plan_id=p.plan_id
    JOIN dbo.service_item si ON si.service_id=i.service_id
    WHERE p.service_package_name LIKE N'M3T2030照护方案-[0-9][0-9]'
      AND NOT (si.service_name=N'M2测试-上门做饭' AND si.service_type=N'助餐' AND si.duration=60 AND si.charge_unit=N'次' AND si.status=N'上架' AND si.is_subsidizable=1)
) THROW 53111,N'计划明细关联的服务项目与预期不一致。',1;
IF EXISTS(
    SELECT 1 FROM dbo.care_plan p
    JOIN dbo.ability_assessment a ON a.elder_id=p.elder_id
    WHERE p.service_package_name LIKE N'M3T2030照护方案-[0-9][0-9]'
      AND (a.scale_type<>N'ADL' OR a.score<>90 OR a.ability_level<>N'能力完好' OR a.assessment_date<>'20291215' OR a.valid_until<>'20301214')
) THROW 53112,N'评估数据与本批仿真口径不一致。',1;

SELECT N'B1机构' AS check_item,@B1 AS actual_count,15 AS expected_count
UNION ALL SELECT N'机构总数',(SELECT COUNT(*) FROM dbo.service_org),20
UNION ALL SELECT N'B2新增老人',@B2Elder,16
UNION ALL SELECT N'老人总数',(SELECT COUNT(*) FROM dbo.elder_profile),36
UNION ALL SELECT N'本批评估',@Assess,20
UNION ALL SELECT N'本批照护计划',@Plans,20
UNION ALL SELECT N'本批计划明细',@Items,20
UNION ALL SELECT N'计划对应不同老人',@PlanElders,20
UNION ALL SELECT N'计划对应不同护工',@PlanCaregivers,20;

SELECT p.plan_id,p.elder_id,e.elder_name,p.service_frequency,p.start_date,p.end_date,p.plan_status,
       p.responsible_caregiver_id,i.service_id,si.service_name,si.service_type
FROM dbo.care_plan p
JOIN dbo.elder_profile e ON e.elder_id=p.elder_id
JOIN dbo.care_plan_item i ON i.plan_id=p.plan_id
JOIN dbo.service_item si ON si.service_id=i.service_id
WHERE p.service_package_name LIKE N'M3T2030照护方案-[0-9][0-9]'
ORDER BY e.elder_name;
