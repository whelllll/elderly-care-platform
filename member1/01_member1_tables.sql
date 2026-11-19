/*
社区居家养老智慧服务平台
成员1：老人档案与能力评估模块
SQL Server 2022+，dbo 架构

本脚本创建成员1负责的5张表：
service_org、elder_profile、ability_assessment、care_plan、care_plan_item。
跨模块外键另见 02_member1_cross_module_foreign_keys.sql。
*/

-- 1. 公共服务机构表
IF OBJECT_ID(N'dbo.service_org', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.service_org
    (
        org_id INT IDENTITY(1,1) NOT NULL,
        org_name NVARCHAR(100) NOT NULL,
        contact_person NVARCHAR(50) NOT NULL,
        contact_phone VARCHAR(20) NOT NULL,
        org_address NVARCHAR(200) NOT NULL,
        service_area NVARCHAR(200) NOT NULL,
        org_status NVARCHAR(10) NOT NULL
            CONSTRAINT DF_service_org_org_status DEFAULT (N'正常'),
        remark NVARCHAR(200) NULL,
        CONSTRAINT PK_service_org PRIMARY KEY (org_id),
        CONSTRAINT UQ_service_org_name_address UNIQUE (org_name, org_address),
        CONSTRAINT CK_service_org_org_status
            CHECK (org_status IN (N'正常', N'停用'))
    );
END;
GO

-- 2. 老人档案表
IF OBJECT_ID(N'dbo.elder_profile', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.elder_profile
    (
        elder_id INT IDENTITY(1,1) NOT NULL,
        elder_name NVARCHAR(50) NOT NULL,
        id_card_no CHAR(18) NOT NULL,
        birth_date DATE NOT NULL,
        address NVARCHAR(200) NOT NULL,
        community_name NVARCHAR(50) NOT NULL,
        guardian_name NVARCHAR(50) NULL,
        guardian_phone VARCHAR(20) NULL,
        is_living_alone BIT NOT NULL
            CONSTRAINT DF_elder_profile_is_living_alone DEFAULT (0),
        is_disabled BIT NOT NULL
            CONSTRAINT DF_elder_profile_is_disabled DEFAULT (0),
        is_low_income BIT NOT NULL
            CONSTRAINT DF_elder_profile_is_low_income DEFAULT (0),
        archive_status NVARCHAR(10) NOT NULL
            CONSTRAINT DF_elder_profile_archive_status DEFAULT (N'正常'),
        CONSTRAINT PK_elder_profile PRIMARY KEY (elder_id),
        CONSTRAINT UQ_elder_profile_id_card_no UNIQUE (id_card_no),
        CONSTRAINT CK_elder_profile_archive_status
            CHECK (archive_status IN (N'正常', N'迁出', N'注销')),
        CONSTRAINT CK_elder_profile_is_living_alone
            CHECK (is_living_alone IN (0,1)),
        CONSTRAINT CK_elder_profile_is_disabled
            CHECK (is_disabled IN (0,1)),
        CONSTRAINT CK_elder_profile_is_low_income
            CHECK (is_low_income IN (0,1))
    );
END;
GO

-- 3. 能力评估表
IF OBJECT_ID(N'dbo.ability_assessment', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ability_assessment
    (
        assessment_id INT IDENTITY(1,1) NOT NULL,
        elder_id INT NOT NULL,
        scale_type NVARCHAR(30) NOT NULL,
        score DECIMAL(6,2) NOT NULL,
        ability_level NVARCHAR(20) NOT NULL,
        assessor_name NVARCHAR(50) NOT NULL,
        assessment_date DATE NOT NULL,
        valid_until DATE NOT NULL,
        CONSTRAINT PK_ability_assessment PRIMARY KEY (assessment_id),
        CONSTRAINT FK_ability_assessment_elder
            FOREIGN KEY (elder_id) REFERENCES dbo.elder_profile(elder_id)
            ON DELETE NO ACTION,
        CONSTRAINT CK_ability_assessment_scale_type
            CHECK (scale_type IN (N'ADL', N'简易智能状态')),
        CONSTRAINT CK_ability_assessment_score CHECK (score >= 0),
        CONSTRAINT CK_ability_assessment_level
            CHECK (ability_level IN (N'能力完好', N'轻度失能', N'中度失能', N'重度失能')),
        CONSTRAINT CK_ability_assessment_valid_date
            CHECK (valid_until >= assessment_date)
    );
END;
GO

-- 4. 照护计划表
IF OBJECT_ID(N'dbo.care_plan', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.care_plan
    (
        plan_id INT IDENTITY(1,1) NOT NULL,
        elder_id INT NOT NULL,
        service_package_name NVARCHAR(100) NOT NULL,
        service_frequency NVARCHAR(50) NOT NULL,
        start_date DATE NOT NULL,
        end_date DATE NOT NULL,
        responsible_caregiver_id INT NULL,
        plan_status NVARCHAR(10) NOT NULL
            CONSTRAINT DF_care_plan_plan_status DEFAULT (N'待生效'),
        CONSTRAINT PK_care_plan PRIMARY KEY (plan_id),
        CONSTRAINT FK_care_plan_elder
            FOREIGN KEY (elder_id) REFERENCES dbo.elder_profile(elder_id)
            ON DELETE NO ACTION,
        CONSTRAINT CK_care_plan_date CHECK (end_date >= start_date),
        CONSTRAINT CK_care_plan_status
            CHECK (plan_status IN (N'待生效', N'生效', N'暂停', N'已结束', N'已取消'))
        -- responsible_caregiver_id 的跨模块外键在02脚本中添加
    );
END;
GO

-- 5. 照护计划服务明细表
IF OBJECT_ID(N'dbo.care_plan_item', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.care_plan_item
    (
        plan_item_id INT IDENTITY(1,1) NOT NULL,
        plan_id INT NOT NULL,
        service_id INT NOT NULL,
        CONSTRAINT PK_care_plan_item PRIMARY KEY (plan_item_id),
        CONSTRAINT FK_care_plan_item_plan
            FOREIGN KEY (plan_id) REFERENCES dbo.care_plan(plan_id)
            ON DELETE NO ACTION,
        CONSTRAINT UQ_care_plan_item_plan_service UNIQUE (plan_id, service_id)
        -- service_id 的跨模块外键在02脚本中添加
    );
END;
GO

-- 6. 索引
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name=N'IX_ability_assessment_elder_date'
               AND object_id=OBJECT_ID(N'dbo.ability_assessment'))
    CREATE INDEX IX_ability_assessment_elder_date
    ON dbo.ability_assessment(elder_id, assessment_date DESC);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name=N'IX_care_plan_elder_status_date'
               AND object_id=OBJECT_ID(N'dbo.care_plan'))
    CREATE INDEX IX_care_plan_elder_status_date
    ON dbo.care_plan(elder_id, plan_status, start_date, end_date);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name=N'IX_service_org_status'
               AND object_id=OBJECT_ID(N'dbo.service_org'))
    CREATE INDEX IX_service_org_status
    ON dbo.service_org(org_status)
    INCLUDE (org_name, contact_person, contact_phone);
GO

-- 7. 基础结构检查
SELECT t.name AS table_name, COUNT(c.column_id) AS column_count
FROM sys.tables AS t
LEFT JOIN sys.columns AS c ON c.object_id=t.object_id
WHERE t.schema_id=SCHEMA_ID(N'dbo')
  AND t.name IN (N'service_org',N'elder_profile',N'ability_assessment',N'care_plan',N'care_plan_item')
GROUP BY t.name
ORDER BY t.name;
GO
