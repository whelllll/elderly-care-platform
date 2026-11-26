/*
归档说明：本文件来自用户D盘保存的B1完整脚本。
当前归档保留 @AllowWrite = 0，作为安全归档副本；不要在已经完成B1的测试库中再次执行。
B1成功结果以 evidence/02_B1新增15家机构结果.png 为证。
说明：现有保存文件的写入开关为0，无法仅凭该文件还原执行当时编辑器中的开关值。
*/


/*
========================================================
B1：新增15家机构
用途：在独立测试数据库中验证机构增量导入
目标数据库：M1_B1_B2_Independent_Test

原有基础机构：5家
本次计划新增：15家
预期机构总数：20家

注意：
1. 本脚本只允许在独立测试数据库执行
2. 默认关闭写入开关
3. 合成机构数据仅用于测试，不代表真实机构
4. 正式写入前仍需确认合成数据口径
5. 发生异常时自动回滚
========================================================
*/

-- 一、切换到独立测试数据库
USE [M1_B1_B2_Independent_Test];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;

-- 二、执行参数
DECLARE @AllowWrite BIT = 0;
DECLARE @TargetDatabase SYSNAME =
    N'M1_B1_B2_Independent_Test';

DECLARE @InsertedRows INT = 0;

-- 三、检查当前数据库和事务状态
IF DB_NAME() <> @TargetDatabase
BEGIN
    THROW 53000, N'当前数据库与目标独立测试库不一致，停止执行。', 1;
END;

IF @@TRANCOUNT <> 0
BEGIN
    THROW 53000, N'检测到外层事务，请先结束外层事务。', 1;
END;

-- 四、检查数据库结构基线
IF
(
    SELECT COUNT(*)
    FROM sys.tables
    WHERE is_ms_shipped = 0
) <> 22

OR
(
    SELECT COUNT(*)
    FROM sys.columns c
    INNER JOIN sys.tables t
        ON c.object_id = t.object_id
    WHERE t.is_ms_shipped = 0
) <> 246

OR
(
    SELECT COUNT(*)
    FROM sys.foreign_keys
) <> 40

OR EXISTS
(
    SELECT 1
    FROM sys.foreign_keys
    WHERE is_disabled = 1
       OR is_not_trusted = 1
)

OR EXISTS
(
    SELECT 1
    FROM sys.check_constraints
    WHERE is_disabled = 1
       OR is_not_trusted = 1
)

OR
(
    SELECT COUNT(*)
    FROM sys.triggers
    WHERE parent_class = 1
      AND is_disabled = 0
) <> 3

BEGIN
    THROW 53000, N'数据库结构或完整性基线不符合要求。', 1;
END;

-- 五、检查B1执行前的22张表数据量
DECLARE @Expected TABLE
(
    table_name SYSNAME PRIMARY KEY,
    expected_count BIGINT NOT NULL
);

INSERT INTO @Expected
(
    table_name,
    expected_count
)
VALUES
(N'ability_assessment', 0),
(N'care_plan', 0),
(N'care_plan_item', 0),
(N'caregiver', 22),
(N'caregiver_certificate', 24),
(N'caregiver_schedule', 22),
(N'dispatch_record', 0),
(N'elder_profile', 20),
(N'emergency_event', 0),
(N'monitor_device', 0),
(N'quality_inspection', 0),
(N'rectification', 0),
(N'service_item', 20),
(N'service_order', 0),
(N'service_org', 5),
(N'subsidy_application', 0),
(N'subsidy_application_item', 0),
(N'subsidy_audit_log', 0),
(N'subsidy_policy', 0),
(N'sys_user', 0),
(N'vital_sign', 0),
(N'work_record', 0);

DECLARE @Actual TABLE
(
    table_name SYSNAME PRIMARY KEY,
    actual_count BIGINT NOT NULL
);

INSERT INTO @Actual
(
    table_name,
    actual_count
)
SELECT N'ability_assessment', COUNT_BIG(*) FROM dbo.ability_assessment
UNION ALL
SELECT N'care_plan', COUNT_BIG(*) FROM dbo.care_plan
UNION ALL
SELECT N'care_plan_item', COUNT_BIG(*) FROM dbo.care_plan_item
UNION ALL
SELECT N'caregiver', COUNT_BIG(*) FROM dbo.caregiver
UNION ALL
SELECT N'caregiver_certificate', COUNT_BIG(*) FROM dbo.caregiver_certificate
UNION ALL
SELECT N'caregiver_schedule', COUNT_BIG(*) FROM dbo.caregiver_schedule
UNION ALL
SELECT N'dispatch_record', COUNT_BIG(*) FROM dbo.dispatch_record
UNION ALL
SELECT N'elder_profile', COUNT_BIG(*) FROM dbo.elder_profile
UNION ALL
SELECT N'emergency_event', COUNT_BIG(*) FROM dbo.emergency_event
UNION ALL
SELECT N'monitor_device', COUNT_BIG(*) FROM dbo.monitor_device
UNION ALL
SELECT N'quality_inspection', COUNT_BIG(*) FROM dbo.quality_inspection
UNION ALL
SELECT N'rectification', COUNT_BIG(*) FROM dbo.rectification
UNION ALL
SELECT N'service_item', COUNT_BIG(*) FROM dbo.service_item
UNION ALL
SELECT N'service_order', COUNT_BIG(*) FROM dbo.service_order
UNION ALL
SELECT N'service_org', COUNT_BIG(*) FROM dbo.service_org
UNION ALL
SELECT N'subsidy_application', COUNT_BIG(*) FROM dbo.subsidy_application
UNION ALL
SELECT N'subsidy_application_item', COUNT_BIG(*) FROM dbo.subsidy_application_item
UNION ALL
SELECT N'subsidy_audit_log', COUNT_BIG(*) FROM dbo.subsidy_audit_log
UNION ALL
SELECT N'subsidy_policy', COUNT_BIG(*) FROM dbo.subsidy_policy
UNION ALL
SELECT N'sys_user', COUNT_BIG(*) FROM dbo.sys_user
UNION ALL
SELECT N'vital_sign', COUNT_BIG(*) FROM dbo.vital_sign
UNION ALL
SELECT N'work_record', COUNT_BIG(*) FROM dbo.work_record;

-- 如果实际数据量与预期不一致，则停止
IF EXISTS
(
    SELECT 1
    FROM @Expected e
    LEFT JOIN @Actual a
        ON e.table_name = a.table_name
    WHERE a.table_name IS NULL
       OR a.actual_count <> e.expected_count
)
BEGIN
    SELECT
        e.table_name AS 表名,
        e.expected_count AS 预期数量,
        a.actual_count AS 实际数量
    FROM @Expected e
    LEFT JOIN @Actual a
        ON e.table_name = a.table_name
    WHERE a.table_name IS NULL
       OR a.actual_count <> e.expected_count;

    THROW 53000, N'B1阶段前置数据量不符合要求，停止执行。', 1;
END;

-- 六、准备本次新增的15家合成机构
DECLARE @NewOrgs TABLE
(
    org_name NVARCHAR(100) NOT NULL,
    contact_person NVARCHAR(50) NOT NULL,
    contact_phone VARCHAR(20) NOT NULL,
    org_address NVARCHAR(200) NOT NULL,
    service_area NVARCHAR(200) NOT NULL,
    org_status NVARCHAR(10) NOT NULL,
    remark NVARCHAR(200) NULL,
    PRIMARY KEY (org_name, org_address)
);

;WITH N AS
(
    SELECT n
    FROM
    (
        VALUES
        (1),(2),(3),(4),(5),
        (6),(7),(8),(9),(10),
        (11),(12),(13),(14),(15)
    ) AS V(n)
)
INSERT INTO @NewOrgs
(
    org_name,
    contact_person,
    contact_phone,
    org_address,
    service_area,
    org_status,
    remark
)
SELECT
    N'M3T2030联调机构'
        + RIGHT('00' + CONVERT(VARCHAR(2), n), 2),

    N'合成联系人',

    '00000000000',

    N'阳光社区联调路'
        + RIGHT('00' + CONVERT(VARCHAR(2), n), 2)
        + N'号',

    N'阳光社区',

    N'正常',

    N'第二批合成机构；非真实机构'

FROM N;

-- 七、检查本次准备的数据数量
IF (SELECT COUNT(*) FROM @NewOrgs) <> 15
BEGIN
    THROW 53000, N'本次待新增机构数量不是15家，停止执行。', 1;
END;

-- 八、检查是否与现有机构发生复合唯一键冲突
IF EXISTS
(
    SELECT 1
    FROM dbo.service_org AS o
    INNER JOIN @NewOrgs AS n
        ON o.org_name = n.org_name
       AND o.org_address = n.org_address
)
BEGIN
    THROW 53000, N'发现重复机构名称和地址组合，停止执行。', 1;
END;

-- 九、写入开关关闭时，只进行只读检查
IF @AllowWrite = 0
BEGIN
    SELECT
        N'只读检查通过，写入开关关闭，尚未新增机构。' AS 执行结果,
        DB_NAME() AS 当前数据库,
        (SELECT COUNT_BIG(*) FROM dbo.service_org) AS 当前机构数量,
        (SELECT COUNT(*) FROM @NewOrgs) AS 计划新增数量,
        CAST(0 AS BIT) AS 是否执行写入;

    RETURN;
END;

-- ======================================================
-- 十、正式执行B1数据写入
-- 只有确认合成数据口径后，才将 @AllowWrite 改为1
-- ======================================================

BEGIN TRY

    BEGIN TRANSACTION;

    -- 在事务内再次检查机构数量
    IF (SELECT COUNT_BIG(*) FROM dbo.service_org) <> 5
    BEGIN
        THROW 53001, N'机构当前数量不再是5家，停止写入。', 1;
    END;

    -- 再次检查重复机构
    IF EXISTS
    (
        SELECT 1
        FROM dbo.service_org AS o
        INNER JOIN @NewOrgs AS n
            ON o.org_name = n.org_name
           AND o.org_address = n.org_address
    )
    BEGIN
        THROW 53002, N'发现重复机构，事务回滚。', 1;
    END;

    -- 插入15家机构
    INSERT INTO dbo.service_org
    (
        org_name,
        contact_person,
        contact_phone,
        org_address,
        service_area,
        org_status,
        remark
    )
    SELECT
        org_name,
        contact_person,
        contact_phone,
        org_address,
        service_area,
        org_status,
        remark
    FROM @NewOrgs;

    SET @InsertedRows = @@ROWCOUNT;

    -- 检查实际新增数量
    IF @InsertedRows <> 15
    BEGIN
        THROW 53003, N'实际新增机构数量不是15家，事务回滚。', 1;
    END;

    -- 检查机构总数量
    IF (SELECT COUNT_BIG(*) FROM dbo.service_org) <> 20
    BEGIN
        THROW 53004, N'机构总数不是20家，事务回滚。', 1;
    END;

    -- 检查本批次机构是否全部存在
    IF
    (
        SELECT COUNT_BIG(*)
        FROM dbo.service_org o
        INNER JOIN @NewOrgs n
            ON o.org_name = n.org_name
           AND o.org_address = n.org_address
    ) <> 15
    BEGIN
        THROW 53005, N'本批次机构完整性检查失败，事务回滚。', 1;
    END;

    COMMIT TRANSACTION;

END TRY
BEGIN CATCH

    -- 发生异常时回滚
    IF XACT_STATE() <> 0
    BEGIN
        ROLLBACK TRANSACTION;
    END;

    THROW;

END CATCH;

-- ======================================================
-- 十一、输出本次新增机构及最终统计结果
-- ======================================================

SELECT
    org_id AS 机构编号,
    org_name AS 机构名称,
    contact_person AS 联系人,
    contact_phone AS 联系电话,
    org_address AS 机构地址,
    service_area AS 服务区域,
    org_status AS 机构状态,
    remark AS 备注
FROM dbo.service_org
WHERE org_name LIKE N'M3T2030联调机构%'
ORDER BY org_name;

SELECT
    COUNT_BIG(*) AS 当前机构总数,
    @InsertedRows AS 本次实际新增数量
FROM dbo.service_org;
GO
