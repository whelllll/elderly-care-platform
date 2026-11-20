/* ============================================================
   社区居家养老智慧服务平台 · 公共共享表 sys_user
   作用：公共用户账号及人员身份
   负责人：成员4
   数据库：Microsoft SQL Server 2022
   架构：dbo
   ------------------------------------------------------------
   设计说明：
   1. 一张表保存“登录账号 + 人员身份”：
      账号：username / password_hash / password_salt / user_status
      身份：role_code + elder_id / caregiver_id / org_id
   2. 一人一角色（role_code）；如以后需要兼岗，再增加
      sys_user_role 关联表，不在本表塞多个角色。
   3. 老人档案、护工档案、机构信息仍由各自表保存，
      本表只存外键，不重复存姓名/身份证/证书等业务字段。
   ------------------------------------------------------------
   先决条件：
      dbo.service_org、dbo.elder_profile 已存在。
     dbo.caregiver 如已存在，脚本会自动补外键；
     如尚未提交，可先建表，等成员3 表就绪后执行
     11_sys_user_caregiver_fk.sql。
   ============================================================ */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ---------- 先决条件检查 ---------- */
IF OBJECT_ID(N'dbo.service_org', N'U') IS NULL
BEGIN
    ;THROW 53001, N'缺少 dbo.service_org，请先执行成员1 的机构表脚本。', 1;
END;

IF OBJECT_ID(N'dbo.elder_profile', N'U') IS NULL
BEGIN
    ;THROW 53002, N'缺少 dbo.elder_profile，请先执行成员1 的老人档案表脚本。', 1;
END;
GO

/* ---------- 建表 ---------- */
IF OBJECT_ID(N'dbo.sys_user', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.sys_user
    (
        user_id          INT           IDENTITY(1,1) NOT NULL,
        username         NVARCHAR(50)  NOT NULL,
        password_hash    VARCHAR(256)  NOT NULL,
        password_salt    VARCHAR(64)   NOT NULL,
        real_name        NVARCHAR(50)  NOT NULL,
        phone            VARCHAR(20)   NULL,
        email            VARCHAR(100)  NULL,
        role_code        NVARCHAR(30)  NOT NULL,
        org_id           INT           NULL,
        elder_id         INT           NULL,
        caregiver_id     INT           NULL,
        user_status      NVARCHAR(10)  NOT NULL
            CONSTRAINT DF_sys_user_status DEFAULT N'正常',
        login_fail_count INT           NOT NULL
            CONSTRAINT DF_sys_user_fail DEFAULT 0,
        lock_until       DATETIME2(0)  NULL,
        last_login_time  DATETIME2(0)  NULL,
        pwd_update_time  DATETIME2(0)  NULL,
        created_at       DATETIME2(0)  NOT NULL
            CONSTRAINT DF_sys_user_created_at DEFAULT SYSDATETIME(),
        updated_at       DATETIME2(0)  NOT NULL
            CONSTRAINT DF_sys_user_updated_at DEFAULT SYSDATETIME(),

        CONSTRAINT PK_sys_user PRIMARY KEY CLUSTERED (user_id),
        CONSTRAINT UQ_user_username UNIQUE (username),
        CONSTRAINT FK_sys_user_org_id FOREIGN KEY (org_id)
            REFERENCES dbo.service_org (org_id) ON DELETE NO ACTION,
        CONSTRAINT FK_sys_user_elder_id FOREIGN KEY (elder_id)
            REFERENCES dbo.elder_profile (elder_id) ON DELETE NO ACTION,

        CONSTRAINT CK_user_role CHECK
            (role_code IN (
                N'COMMUNITY_ADMIN', N'ELDER', N'FAMILY', N'CAREGIVER',
                N'ORG_MANAGER', N'STREET_SUPERVISOR', N'CIVIL_SUPERVISOR', N'SYS_ADMIN'
            )),
        CONSTRAINT CK_user_status CHECK
            (user_status IN (N'正常', N'停用', N'锁定')),
        CONSTRAINT CK_user_fail_count CHECK
            (login_fail_count BETWEEN 0 AND 5),
        CONSTRAINT CK_user_lock CHECK
            ((user_status = N'锁定' AND lock_until IS NOT NULL)
             OR (user_status <> N'锁定' AND lock_until IS NULL)),

        /* 身份与角色必须匹配：
           老人/家属绑老人；护工绑护工；社区管理员/机构负责人绑机构；
           街道/民政/系统管理员不绑老人/护工。 */
        CONSTRAINT CK_user_role_identity CHECK
        (
            (role_code IN (N'ELDER', N'FAMILY')
                AND elder_id IS NOT NULL AND caregiver_id IS NULL)
            OR
            (role_code = N'CAREGIVER'
                AND caregiver_id IS NOT NULL AND elder_id IS NULL)
            OR
            (role_code IN (N'COMMUNITY_ADMIN', N'ORG_MANAGER')
                AND org_id IS NOT NULL AND elder_id IS NULL AND caregiver_id IS NULL)
            OR
            (role_code IN (N'STREET_SUPERVISOR', N'CIVIL_SUPERVISOR', N'SYS_ADMIN')
                AND elder_id IS NULL AND caregiver_id IS NULL)
        )
    );
END;
GO

/* 一个护工最多绑定一个账号 */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'UQ_user_caregiver'
                 AND object_id = OBJECT_ID(N'dbo.sys_user'))
BEGIN
    CREATE UNIQUE INDEX UQ_user_caregiver
        ON dbo.sys_user (caregiver_id)
        WHERE caregiver_id IS NOT NULL;
END;
GO

/* 常用查询索引 */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_sys_user_role_status'
                 AND object_id = OBJECT_ID(N'dbo.sys_user'))
    CREATE INDEX IX_sys_user_role_status
        ON dbo.sys_user (role_code, user_status)
        INCLUDE (real_name, org_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_sys_user_org'
                 AND object_id = OBJECT_ID(N'dbo.sys_user'))
    CREATE INDEX IX_sys_user_org
        ON dbo.sys_user (org_id, user_status);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_sys_user_elder'
                 AND object_id = OBJECT_ID(N'dbo.sys_user'))
    CREATE INDEX IX_sys_user_elder
        ON dbo.sys_user (elder_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = N'IX_sys_user_lock'
                 AND object_id = OBJECT_ID(N'dbo.sys_user'))
    CREATE INDEX IX_sys_user_lock
        ON dbo.sys_user (user_status, lock_until);
GO

/* 成员3 的 caregiver 表如已存在，直接补外键；否则由 11 号脚本后补 */
IF OBJECT_ID(N'dbo.caregiver', N'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.foreign_keys
                   WHERE name = N'FK_sys_user_caregiver_id')
BEGIN
    ALTER TABLE dbo.sys_user
        ADD CONSTRAINT FK_sys_user_caregiver_id FOREIGN KEY (caregiver_id)
        REFERENCES dbo.caregiver (caregiver_id) ON DELETE NO ACTION;
END;
GO

PRINT N'sys_user（公共用户账号及人员身份）建表完成。';
GO
