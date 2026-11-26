/*
B1/B2执行前只读预检脚本
用途：不写入任何数据，核对目标库、结构基线和B1/B2阶段前置数据量。
先将 @Phase 设为 B1 运行；B1成功后再将其改为 B2 运行。
预检通过不等于已经授权写入；B1/B2脚本中的 @AllowWrite 仍须在确认隔离测试库后另行开启。
*/
USE [M1_B1_B2_Independent_Test];
GO
SET NOCOUNT ON;
DECLARE @Phase varchar(2)='B1'; -- B1执行前填B1；B1成功后执行B2前改成B2
DECLARE @TargetDatabase sysname=N'M1_B1_B2_Independent_Test';
IF @Phase NOT IN ('B1','B2') THROW 53200,N'@Phase只能是B1或B2。',1;
IF DB_NAME()<>@TargetDatabase THROW 53201,N'当前数据库与预检目标库不一致，请先确认隔离测试库。',1;
IF (SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped=0)<>22
 OR (SELECT COUNT(*) FROM sys.columns c JOIN sys.tables t ON t.object_id=c.object_id WHERE t.is_ms_shipped=0)<>246
 OR (SELECT COUNT(*) FROM sys.foreign_keys)<>40
 OR EXISTS(SELECT 1 FROM sys.foreign_keys WHERE is_disabled=1 OR is_not_trusted=1)
 OR EXISTS(SELECT 1 FROM sys.check_constraints WHERE is_disabled=1 OR is_not_trusted=1)
 OR (SELECT COUNT(*) FROM sys.triggers WHERE parent_class=1 AND is_disabled=0)<>3
    THROW 53202,N'结构或完整性基线不符合B1/B2脚本要求。',1;

DECLARE @Expected table(table_name sysname PRIMARY KEY,expected_count bigint NOT NULL);
INSERT @Expected(table_name,expected_count) VALUES
(N'ability_assessment',0),(N'care_plan',0),(N'care_plan_item',0),
(N'caregiver',22),(N'caregiver_certificate',24),(N'caregiver_schedule',22),
(N'dispatch_record',0),(N'elder_profile',20),(N'emergency_event',0),
(N'monitor_device',0),(N'quality_inspection',0),(N'rectification',0),
(N'service_item',20),(N'service_order',0),
(N'service_org',CASE WHEN @Phase='B1' THEN 5 ELSE 20 END),
(N'subsidy_application',0),(N'subsidy_application_item',0),(N'subsidy_audit_log',0),
(N'subsidy_policy',0),(N'sys_user',0),(N'vital_sign',0),(N'work_record',0);

DECLARE @Actual table(table_name sysname PRIMARY KEY,actual_count bigint NOT NULL);
INSERT @Actual(table_name,actual_count)
SELECT N'ability_assessment',COUNT_BIG(*) FROM dbo.ability_assessment UNION ALL
SELECT N'care_plan',COUNT_BIG(*) FROM dbo.care_plan UNION ALL
SELECT N'care_plan_item',COUNT_BIG(*) FROM dbo.care_plan_item UNION ALL
SELECT N'caregiver',COUNT_BIG(*) FROM dbo.caregiver UNION ALL
SELECT N'caregiver_certificate',COUNT_BIG(*) FROM dbo.caregiver_certificate UNION ALL
SELECT N'caregiver_schedule',COUNT_BIG(*) FROM dbo.caregiver_schedule UNION ALL
SELECT N'dispatch_record',COUNT_BIG(*) FROM dbo.dispatch_record UNION ALL
SELECT N'elder_profile',COUNT_BIG(*) FROM dbo.elder_profile UNION ALL
SELECT N'emergency_event',COUNT_BIG(*) FROM dbo.emergency_event UNION ALL
SELECT N'monitor_device',COUNT_BIG(*) FROM dbo.monitor_device UNION ALL
SELECT N'quality_inspection',COUNT_BIG(*) FROM dbo.quality_inspection UNION ALL
SELECT N'rectification',COUNT_BIG(*) FROM dbo.rectification UNION ALL
SELECT N'service_item',COUNT_BIG(*) FROM dbo.service_item UNION ALL
SELECT N'service_order',COUNT_BIG(*) FROM dbo.service_order UNION ALL
SELECT N'service_org',COUNT_BIG(*) FROM dbo.service_org UNION ALL
SELECT N'subsidy_application',COUNT_BIG(*) FROM dbo.subsidy_application UNION ALL
SELECT N'subsidy_application_item',COUNT_BIG(*) FROM dbo.subsidy_application_item UNION ALL
SELECT N'subsidy_audit_log',COUNT_BIG(*) FROM dbo.subsidy_audit_log UNION ALL
SELECT N'subsidy_policy',COUNT_BIG(*) FROM dbo.subsidy_policy UNION ALL
SELECT N'sys_user',COUNT_BIG(*) FROM dbo.sys_user UNION ALL
SELECT N'vital_sign',COUNT_BIG(*) FROM dbo.vital_sign UNION ALL
SELECT N'work_record',COUNT_BIG(*) FROM dbo.work_record;

IF EXISTS(SELECT 1 FROM @Expected e JOIN @Actual a ON a.table_name=e.table_name WHERE a.actual_count<>e.expected_count)
BEGIN
    SELECT e.table_name,e.expected_count,a.actual_count FROM @Expected e JOIN @Actual a ON a.table_name=e.table_name WHERE a.actual_count<>e.expected_count ORDER BY e.table_name;
    THROW 53203,N'阶段前置数据量不符合要求；停止，不要清库或盲目重跑。',1;
END;

IF (SELECT COUNT(*) FROM dbo.service_item WHERE service_name=N'M2测试-上门做饭' AND service_type=N'助餐' AND duration=60 AND charge_unit=N'次' AND status=N'上架' AND is_subsidizable=1)<>1
    THROW 53204,N'服务项目业务条件未唯一命中。',1;
IF (SELECT COUNT(*) FROM dbo.service_org WHERE org_name=N'阳光社区养老服务中心' AND org_address=N'阳光社区服务街道1号' AND org_status=N'正常' AND service_area=N'阳光社区')<>1
    THROW 53205,N'阳光社区基准机构未唯一命中或状态/服务区域不正确。',1;

IF @Phase='B2'
BEGIN
    DECLARE @ServiceID int=(SELECT MIN(service_id) FROM dbo.service_item WHERE service_name=N'M2测试-上门做饭' AND service_type=N'助餐' AND duration=60 AND charge_unit=N'次' AND status=N'上架' AND is_subsidizable=1);
    DECLARE @OrgID int=(SELECT MIN(org_id) FROM dbo.service_org WHERE org_name=N'阳光社区养老服务中心' AND org_address=N'阳光社区服务街道1号');
    DECLARE @Mapped int;
    ;WITH N AS (SELECT n FROM (VALUES(1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12),(13),(14),(15),(16),(17),(18),(19),(20))v(n))
    SELECT @Mapped=COUNT(*)
    FROM N
    JOIN dbo.caregiver c ON c.caregiver_name=N'M3T2030护工'+RIGHT('00'+CONVERT(varchar(2),N.n),2) AND c.org_id=@OrgID AND c.service_area=N'阳光社区' AND c.employment_status=N'在岗'
    JOIN dbo.caregiver_schedule s ON s.caregiver_id=c.caregiver_id AND s.schedule_status=N'开放'
      AND s.start_time=DATEADD(hour,8,CONVERT(datetime2,DATEADD(day,N.n-1,CONVERT(date,'20300105'))))
      AND s.end_time=DATEADD(hour,12,CONVERT(datetime2,DATEADD(day,N.n-1,CONVERT(date,'20300105'))))
    WHERE EXISTS(SELECT 1 FROM dbo.caregiver_certificate x WHERE x.caregiver_id=c.caregiver_id AND x.service_id=@ServiceID AND x.certificate_status=N'有效' AND CONVERT(date,s.start_time) BETWEEN x.valid_from AND x.valid_to);
    IF @Mapped<>20 THROW 53206,N'可用护工/排班/有效资质映射不是20组，B2暂不能执行。',1;
END;

SELECT N'只读预检通过' AS result,@Phase AS phase,DB_NAME() AS database_name;
SELECT e.table_name,e.expected_count,a.actual_count FROM @Expected e JOIN @Actual a ON a.table_name=e.table_name ORDER BY e.table_name;
