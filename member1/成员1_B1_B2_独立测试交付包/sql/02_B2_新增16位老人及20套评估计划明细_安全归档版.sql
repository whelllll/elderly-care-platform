/*
归档说明：本文件以本轮实际执行成功的B2脚本为底稿，仅将 @AllowWrite 从1改为0，作为安全归档副本。
实际执行原版（@AllowWrite=1）另存于 evidence/sql_实际执行留档/02_B2正式写入结果_实际执行版本_勿重跑.sql。
当前数据库已经写入成功，禁止在现有测试库再次执行本脚本或实际执行版本。
*/


/*
========================================================
B2正式执行脚本
新增16位老人、20条能力评估、20份照护计划、20条计划明细

目标数据库：M1_B1_B2_Independent_Test
执行环境：独立测试数据库

注意：
1. 不修改原有注销、迁出老人状态
2. 所有新增数据均为合成测试数据
3. 使用事务，异常自动回滚
4. 不允许重复执行
========================================================
*/

USE [M1_B1_B2_Independent_Test];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;

-- 一、执行参数
DECLARE @AllowWrite BIT = 0;
DECLARE @TargetDatabase SYSNAME = N'M1_B1_B2_Independent_Test';

IF @AllowWrite <> 1
    THROW 53000, N'写入开关未开启。', 1;

IF DB_NAME() <> @TargetDatabase OR @@TRANCOUNT <> 0
    THROW 53000, N'数据库不正确或存在外层事务。', 1;

-- 二、检查数据库结构
IF (SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped=0) <> 22
 OR (SELECT COUNT(*) FROM sys.columns c
     JOIN sys.tables t ON t.object_id=c.object_id
     WHERE t.is_ms_shipped=0) <> 246
 OR (SELECT COUNT(*) FROM sys.foreign_keys) <> 40
 OR EXISTS(SELECT 1 FROM sys.foreign_keys
           WHERE is_disabled=1 OR is_not_trusted=1)
 OR EXISTS(SELECT 1 FROM sys.check_constraints
           WHERE is_disabled=1 OR is_not_trusted=1)
 OR (SELECT COUNT(*) FROM sys.triggers
     WHERE parent_class=1 AND is_disabled=0) <> 3
    THROW 53001, N'数据库结构基线不符合要求。', 1;

-- 三、检查B2执行前的数据量
DECLARE @Expected TABLE
(
    table_name SYSNAME PRIMARY KEY,
    expected_count BIGINT
);

INSERT INTO @Expected VALUES
(N'ability_assessment',0),
(N'care_plan',0),
(N'care_plan_item',0),
(N'caregiver',22),
(N'caregiver_certificate',24),
(N'caregiver_schedule',22),
(N'dispatch_record',0),
(N'elder_profile',20),
(N'emergency_event',0),
(N'monitor_device',0),
(N'quality_inspection',0),
(N'rectification',0),
(N'service_item',20),
(N'service_order',0),
(N'service_org',20),
(N'subsidy_application',0),
(N'subsidy_application_item',0),
(N'subsidy_audit_log',0),
(N'subsidy_policy',0),
(N'sys_user',0),
(N'vital_sign',0),
(N'work_record',0);

DECLARE @Actual TABLE
(
    table_name SYSNAME PRIMARY KEY,
    actual_count BIGINT
);

INSERT INTO @Actual
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

IF EXISTS
(
    SELECT 1 FROM @Expected e
    LEFT JOIN @Actual a ON e.table_name=a.table_name
    WHERE a.table_name IS NULL OR e.expected_count<>a.actual_count
)
BEGIN
    SELECT e.table_name,e.expected_count,a.actual_count
    FROM @Expected e
    LEFT JOIN @Actual a ON e.table_name=a.table_name
    WHERE a.table_name IS NULL OR e.expected_count<>a.actual_count;

    THROW 53002,N'B2前置数据量不正确，停止执行。',1;
END;

-- 四、核对原有老人状态
IF (SELECT COUNT(*) FROM dbo.elder_profile) <> 20
 OR (SELECT COUNT(*) FROM dbo.elder_profile
     WHERE archive_status=N'正常') <> 18
 OR (SELECT COUNT(*) FROM dbo.elder_profile
     WHERE archive_status=N'注销') <> 1
 OR (SELECT COUNT(*) FROM dbo.elder_profile
     WHERE archive_status=N'迁出') <> 1
    THROW 53003,N'原有老人档案状态不符合18正常、1注销、1迁出的基线。',1;

-- 五、准备20位老人
-- 前4位使用已有老人，后16位为新增合成老人
DECLARE @Cohort TABLE
(
    seq INT PRIMARY KEY,
    elder_name NVARCHAR(50),
    id_card_no CHAR(18) UNIQUE,
    birth_date DATE,
    is_new BIT
);

INSERT INTO @Cohort VALUES
(1,NULL,'11010119420617016X',NULL,0),
(2,NULL,'11010119430602001X',NULL,0),
(3,NULL,'11010119500612011X',NULL,0),
(4,NULL,'11010119580607006X',NULL,0),
(5,N'M3T2030阳光老人01','110101194101027014','1941-01-02',1),
(6,N'M3T2030阳光老人02','110101194201037025','1942-01-03',1),
(7,N'M3T2030阳光老人03','110101194301047036','1943-01-04',1),
(8,N'M3T2030阳光老人04','110101194401057047','1944-01-05',1),
(9,N'M3T2030阳光老人05','110101194501067058','1945-01-06',1),
(10,N'M3T2030阳光老人06','110101194601077069','1946-01-07',1),
(11,N'M3T2030阳光老人07','11010119470108707X','1947-01-08',1),
(12,N'M3T2030阳光老人08','110101194801097080','1948-01-09',1),
(13,N'M3T2030阳光老人09','110101194901107098','1949-01-10',1),
(14,N'M3T2030阳光老人10','110101195001117105','1950-01-11',1),
(15,N'M3T2030阳光老人11','110101195101127116','1951-01-12',1),
(16,N'M3T2030阳光老人12','110101195201137127','1952-01-13',1),
(17,N'M3T2030阳光老人13','110101195301147138','1953-01-14',1),
(18,N'M3T2030阳光老人14','110101195401157149','1954-01-15',1),
(19,N'M3T2030阳光老人15','11010119550116715X','1955-01-16',1),
(20,N'M3T2030阳光老人16','110101195601177160','1956-01-17',1);

-- 检查原有4位老人
IF EXISTS
(
    SELECT 1 FROM @Cohort h
    WHERE h.is_new=0
      AND NOT EXISTS
      (
          SELECT 1 FROM dbo.elder_profile e
          WHERE e.id_card_no=h.id_card_no
            AND e.archive_status=N'正常'
            AND e.community_name=N'阳光社区'
      )
)
    THROW 53004,N'原有4位老人不存在、状态异常或不属于阳光社区。',1;

-- 检查16位新增老人是否已经存在
IF EXISTS
(
    SELECT 1 FROM @Cohort h
    JOIN dbo.elder_profile e ON e.id_card_no=h.id_card_no
    WHERE h.is_new=1
)
    THROW 53005,N'发现新增老人身份证号重复，停止执行。',1;

IF EXISTS
(
    SELECT 1 FROM @Cohort h
    JOIN dbo.elder_profile e ON e.elder_name=h.elder_name
    WHERE h.is_new=1
)
    THROW 53005,N'发现新增老人姓名重复，停止执行。',1;

-- 六、核对机构和服务项目
DECLARE @ServiceID INT;
DECLARE @OrgID INT;

SELECT @ServiceID=MIN(service_id)
FROM dbo.service_item
WHERE service_name=N'M2测试-上门做饭'
  AND service_type=N'助餐'
  AND duration=60
  AND charge_unit=N'次'
  AND status=N'上架'
  AND is_subsidizable=1;

IF (SELECT COUNT(*) FROM dbo.service_item
    WHERE service_name=N'M2测试-上门做饭'
      AND service_type=N'助餐'
      AND duration=60
      AND charge_unit=N'次'
      AND status=N'上架'
      AND is_subsidizable=1)<>1
    THROW 53006,N'服务项目未唯一命中。',1;

SELECT @OrgID=MIN(org_id)
FROM dbo.service_org
WHERE org_name=N'阳光社区养老服务中心'
  AND org_address=N'阳光社区服务街道1号'
  AND org_status=N'正常'
  AND service_area=N'阳光社区';

IF (SELECT COUNT(*) FROM dbo.service_org
    WHERE org_name=N'阳光社区养老服务中心'
      AND org_address=N'阳光社区服务街道1号'
      AND org_status=N'正常'
      AND service_area=N'阳光社区')<>1
    THROW 53007,N'基准机构未唯一命中。',1;

-- 七、准备护工、老人、排班映射
DECLARE @Map TABLE
(
    seq INT PRIMARY KEY,
    elder_id INT UNIQUE,
    caregiver_id INT UNIQUE,
    schedule_id INT UNIQUE
);

BEGIN TRY

    BEGIN TRANSACTION;

    -- 1. 新增16位老人
    INSERT INTO dbo.elder_profile
    (
        elder_name,
        id_card_no,
        birth_date,
        address,
        community_name,
        guardian_name,
        guardian_phone,
        is_living_alone,
        is_disabled,
        is_low_income,
        archive_status
    )
    SELECT
        elder_name,
        id_card_no,
        birth_date,
        N'阳光社区-合成联调住宅'+CONVERT(NVARCHAR(3),seq),
        N'阳光社区',
        N'合成监护人',
        '00000000000',
        0,0,0,
        N'正常'
    FROM @Cohort
    WHERE is_new=1;

    IF @@ROWCOUNT<>16
        THROW 53008,N'新增老人数量不是16，回滚。',1;

    -- 2. 建立20组老人、护工、排班映射
    INSERT INTO @Map
    (
        seq,elder_id,caregiver_id,schedule_id
    )
    SELECT
        h.seq,
        e.elder_id,
        c.caregiver_id,
        s.schedule_id
    FROM @Cohort h
    JOIN dbo.elder_profile e
        ON e.id_card_no=h.id_card_no
       AND e.archive_status=N'正常'
       AND e.community_name=N'阳光社区'
    JOIN dbo.caregiver c
        ON c.caregiver_name=N'M3T2030护工'
           +RIGHT('00'+CONVERT(VARCHAR(2),h.seq),2)
       AND c.org_id=@OrgID
       AND c.service_area=N'阳光社区'
       AND c.employment_status=N'在岗'
    JOIN dbo.caregiver_schedule s
        ON s.caregiver_id=c.caregiver_id
       AND s.schedule_status=N'开放'
       AND s.start_time=DATEADD(hour,8,
           CONVERT(datetime2,DATEADD(day,h.seq-1,
           CONVERT(date,'20300105'))))
       AND s.end_time=DATEADD(hour,12,
           CONVERT(datetime2,DATEADD(day,h.seq-1,
           CONVERT(date,'20300105'))))
    WHERE EXISTS
    (
        SELECT 1
        FROM dbo.caregiver_certificate x
        WHERE x.caregiver_id=c.caregiver_id
          AND x.service_id=@ServiceID
          AND x.certificate_status=N'有效'
          AND CONVERT(date,s.start_time)
              BETWEEN x.valid_from AND x.valid_to
    );

    IF @@ROWCOUNT<>20
        THROW 53009,N'20组老人、护工、排班映射不完整，回滚。',1;

    -- 3. 新增20条能力评估
    INSERT INTO dbo.ability_assessment
    (
        elder_id,
        scale_type,
        score,
        ability_level,
        assessor_name,
        assessment_date,
        valid_until
    )
    SELECT
        elder_id,
        N'ADL',
        90,
        N'能力完好',
        N'合成评估员',
        CONVERT(date,'20291215'),
        CONVERT(date,'20301214')
    FROM @Map;

    IF @@ROWCOUNT<>20
        THROW 53010,N'能力评估新增数量不是20，回滚。',1;

    -- 4. 新增20份2030年照护计划
    INSERT INTO dbo.care_plan
    (
        elder_id,
        service_package_name,
        service_frequency,
        start_date,
        end_date,
        responsible_caregiver_id,
        plan_status
    )
    SELECT
        elder_id,
        N'M3T2030照护方案-'
            +RIGHT('00'+CONVERT(VARCHAR(2),seq),2),
        N'每月1次',
        CONVERT(date,'20300101'),
        CONVERT(date,'20300131'),
        caregiver_id,
        N'待生效'
    FROM @Map;

    IF @@ROWCOUNT<>20
        THROW 53011,N'照护计划新增数量不是20，回滚。',1;

    -- 5. 新增20条照护计划服务明细
    INSERT INTO dbo.care_plan_item
    (
        plan_id,
        service_id
    )
    SELECT
        p.plan_id,
        @ServiceID
    FROM @Map m
    JOIN dbo.care_plan p
        ON p.elder_id=m.elder_id
       AND p.service_package_name=
           N'M3T2030照护方案-'
           +RIGHT('00'+CONVERT(VARCHAR(2),m.seq),2)
       AND p.responsible_caregiver_id=m.caregiver_id
       AND p.start_date=CONVERT(date,'20300101')
       AND p.end_date=CONVERT(date,'20300131');

    IF @@ROWCOUNT<>20
        THROW 53012,N'计划明细新增数量不是20，回滚。',1;

    -- 6. 检查计划区间是否重叠
    IF EXISTS
    (
        SELECT 1
        FROM dbo.care_plan a
        JOIN dbo.care_plan b
          ON a.elder_id=b.elder_id
         AND a.plan_id<b.plan_id
        WHERE a.plan_status IN(N'待生效',N'生效')
          AND b.plan_status IN(N'待生效',N'生效')
          AND a.start_date<=b.end_date
          AND b.start_date<=a.end_date
    )
        THROW 53013,N'发现有效照护计划时间重叠，回滚。',1;

    -- 7. 检查新增后的老人状态
    IF (SELECT COUNT(*) FROM dbo.elder_profile)<>36
       OR (SELECT COUNT(*) FROM dbo.elder_profile
           WHERE archive_status=N'正常')<>34
       OR (SELECT COUNT(*) FROM dbo.elder_profile
           WHERE archive_status=N'注销')<>1
       OR (SELECT COUNT(*) FROM dbo.elder_profile
           WHERE archive_status=N'迁出')<>1
        THROW 53014,N'老人档案总数或状态不符合预期，回滚。',1;

    -- 8. 检查本批次关联数据
    IF (SELECT COUNT(*) FROM dbo.ability_assessment)<>20
       OR (SELECT COUNT(*) FROM dbo.care_plan
           WHERE service_package_name LIKE N'M3T2030照护方案-[0-9][0-9]')<>20
       OR (SELECT COUNT(*) FROM dbo.care_plan_item i
           JOIN dbo.care_plan p ON p.plan_id=i.plan_id
           WHERE p.service_package_name LIKE N'M3T2030照护方案-[0-9][0-9]')<>20
        THROW 53015,N'评估、计划或明细数量不正确，回滚。',1;

    COMMIT TRANSACTION;

END TRY
BEGIN CATCH

    IF XACT_STATE()<>0
        ROLLBACK TRANSACTION;

    THROW;

END CATCH;

-- 八、输出最终结果
SELECT
    N'B2正式写入成功' AS 执行结果,
    DB_NAME() AS 当前数据库;

SELECT N'老人档案总数' AS 核验项目,
       COUNT(*) AS 实际数量
FROM dbo.elder_profile
UNION ALL
SELECT N'正常老人总数',COUNT(*)
FROM dbo.elder_profile
WHERE archive_status=N'正常'
UNION ALL
SELECT N'新增能力评估',COUNT(*)
FROM dbo.ability_assessment
UNION ALL
SELECT N'新增照护计划',COUNT(*)
FROM dbo.care_plan
WHERE service_package_name LIKE N'M3T2030照护方案-[0-9][0-9]'
UNION ALL
SELECT N'新增计划明细',COUNT(*)
FROM dbo.care_plan_item i
JOIN dbo.care_plan p ON p.plan_id=i.plan_id
WHERE p.service_package_name LIKE N'M3T2030照护方案-[0-9][0-9]';

-- 输出20组关联关系
SELECT
    m.seq AS 序号,
    e.elder_name AS 老人姓名,
    c.caregiver_name AS 护工姓名,
    p.service_package_name AS 照护计划,
    p.service_frequency AS 服务频次,
    p.start_date AS 计划开始日期,
    p.end_date AS 计划结束日期,
    p.plan_status AS 计划状态
FROM @Map m
JOIN dbo.elder_profile e ON e.elder_id=m.elder_id
JOIN dbo.caregiver c ON c.caregiver_id=m.caregiver_id
JOIN dbo.care_plan p ON p.elder_id=m.elder_id
ORDER BY m.seq;
GO
