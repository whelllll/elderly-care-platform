/* ============================================================
   B3 正式联调账号：精确 28 个
   ------------------------------------------------------------
   组成：
     20 个在岗护工（CAREGIVER）
      1 个 SYS_ADMIN
      1 个 COMMUNITY_ADMIN
      1 个 STREET_SUPERVISOR
      1 个 CIVIL_SUPERVISOR
      2 个 ORG_MANAGER（两个不同机构）
      1 个 ELDER
      1 个 FAMILY
   ------------------------------------------------------------
   特点：
     1. 不使用 10/12 号脚本，避免生成 5 老人/5 家属/3 机构管理员等多余账号；
     2. 不写死 elder_id / caregiver_id / org_id，按实际业务数据关联；
     3. 28 个账号分别使用独立随机盐和 PBKDF2-HMAC-SHA256 哈希；
     4. 只适用于 sys_user 为空表；已有账号请先确认，不要直接叠加；
     5. 不重跑 09，也不重跑 M3 05 BASE；M3 BASE 数据必须已经存在。
   ------------------------------------------------------------
   测试密码：Admin@123
   哈希格式：Base64(PBKDF2-HMAC-SHA256(password, salt, 100000))
   ============================================================ */

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID(N'dbo.sys_user', N'U') IS NULL
    THROW 56001, N'缺少 dbo.sys_user，请先执行 09_sys_user.sql。', 1;

IF OBJECT_ID(N'dbo.caregiver', N'U') IS NULL
    THROW 56002, N'缺少 dbo.caregiver，请先执行成员3 建表脚本。', 1;

IF OBJECT_ID(N'dbo.elder_profile', N'U') IS NULL
    THROW 56003, N'缺少 dbo.elder_profile，请先执行成员1 建表脚本。', 1;

IF OBJECT_ID(N'dbo.service_org', N'U') IS NULL
    THROW 56004, N'缺少 dbo.service_org，请先执行成员1 建表脚本。', 1;

IF EXISTS (SELECT 1 FROM dbo.sys_user)
BEGIN
    ;THROW 56005, N'sys_user 非空。B3 是 28 个账号的独立初始化脚本，请先确认现有账号来源，不要和 10/12 叠加。', 1;
END;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @account TABLE
    (
        seq          INT PRIMARY KEY,
        username     NVARCHAR(50)  NOT NULL,
        real_name    NVARCHAR(50)  NOT NULL,
        role_code    NVARCHAR(30)  NOT NULL,
        org_id       INT           NULL,
        elder_id     INT           NULL,
        caregiver_id INT           NULL
    );

    /* 1. 20 个在岗护工：按姓名、编号排序取前 20，不写死 ID */
    ;WITH cg AS
    (
        SELECT TOP (20)
            c.caregiver_id,
            c.caregiver_name,
            c.org_id,
            ROW_NUMBER() OVER (ORDER BY c.caregiver_name, c.caregiver_id) AS rn
        FROM dbo.caregiver AS c
        WHERE c.employment_status = N'在岗'
    )
    INSERT INTO @account (seq, username, real_name, role_code, org_id, elder_id, caregiver_id)
    SELECT
        cg.rn,
        N'caregiver_' + CONVERT(NVARCHAR(10), cg.caregiver_id),
        cg.caregiver_name,
        N'CAREGIVER',
        cg.org_id,
        NULL,
        cg.caregiver_id
    FROM cg;

    IF (SELECT COUNT(*) FROM @account) <> 20
        THROW 56006, N'在岗护工不足 20 名，无法生成 20 个护工账号。', 1;

    /* 2. 两个不同正常机构 + 一个老人 */
    DECLARE @org1 INT, @org2 INT, @org1_name NVARCHAR(100), @org2_name NVARCHAR(100);
    ;WITH o AS
    (
        SELECT org_id, org_name,
               ROW_NUMBER() OVER (ORDER BY org_name) AS rn
        FROM dbo.service_org
        WHERE org_status = N'正常'
    )
    SELECT
        @org1 = MAX(CASE WHEN rn = 1 THEN org_id END),
        @org1_name = MAX(CASE WHEN rn = 1 THEN org_name END),
        @org2 = MAX(CASE WHEN rn = 2 THEN org_id END),
        @org2_name = MAX(CASE WHEN rn = 2 THEN org_name END)
    FROM o;

    IF @org1 IS NULL OR @org2 IS NULL
        THROW 56007, N'正常机构不足 2 家，无法生成 2 个 ORG_MANAGER。', 1;

    DECLARE @elder_id INT, @elder_name NVARCHAR(50), @id_card NVARCHAR(20);
    SELECT TOP (1)
        @elder_id = elder_id,
        @elder_name = elder_name,
        @id_card = id_card_no
    FROM dbo.elder_profile
    WHERE archive_status = N'正常'
    ORDER BY id_card_no;

    IF @elder_id IS NULL
        THROW 56008, N'没有正常老人，无法生成 ELDER / FAMILY 账号。', 1;

    /* 3. 其余 8 个账号 */
    INSERT INTO @account (seq, username, real_name, role_code, org_id, elder_id, caregiver_id)
    VALUES
        (21, N'admin',      N'系统管理员', N'SYS_ADMIN',          NULL,  NULL,     NULL),
        (22, N'comm_admin', N'社区管理员', N'COMMUNITY_ADMIN',    @org1, NULL,     NULL),
        (23, N'street_sup', N'街道监管员', N'STREET_SUPERVISOR',  NULL,  NULL,     NULL),
        (24, N'civil_sup',  N'民政监管员', N'CIVIL_SUPERVISOR',   NULL,  NULL,     NULL),
        (25, N'org_mgr_1',  LEFT(N'机构负责人_' + @org1_name, 50), N'ORG_MANAGER', @org1, NULL, NULL),
        (26, N'org_mgr_2',  LEFT(N'机构负责人_' + @org2_name, 50), N'ORG_MANAGER', @org2, NULL, NULL),
        (27, N'elder_' + @id_card, @elder_name, N'ELDER', NULL, @elder_id, NULL),
        (28, N'family_' + @id_card, LEFT(@elder_name + N'家属', 50), N'FAMILY', NULL, @elder_id, NULL);

    IF (SELECT COUNT(*) FROM @account) <> 28
        THROW 56009, N'账号模板不是 28 条，停止写入。', 1;

    /* 4. 28 组独立盐 / 哈希 */
    DECLARE @cred TABLE
    (
        seq           INT PRIMARY KEY,
        password_salt VARCHAR(64)  NOT NULL,
        password_hash VARCHAR(256) NOT NULL
    );

    INSERT INTO @cred (seq, password_salt, password_hash)
    VALUES
    (1, 'XCHtFI2qPl9fHmiOvgNwCQ==', 'te5eJIT85kj8HW40LwpXDiYfFgQo/TMTtGePFgkvaQI='),
    (2, 'VjFq5SZAluVnC47zkwe0kA==', 'hlBblH5v8GG1ssSW1EQRb04Fhg03zUgE8PUDTuHgTM0='),
    (3, 'fyVSU6fwmyYFhUwY0/lXuQ==', 'GwIBnWeV+mkAHlmWpFeGLcnwYoXifjuu7CibJ5Vd5pg='),
    (4, 'plDmvhrQa18SSXC4yxK9sw==', '23LNTOH634t7E77mol85rtDDNJ/XjRHrrZY3/9W6cQY='),
    (5, '9CWwZ+dffeeOxyBhpKvv8Q==', 'jLBQ9W95ySw4UjX/yoGogZa21Evk8I/C+CD1eoERHSU='),
    (6, 'u12NkjksFO7TPuStK/FNsA==', '8puMsF4WopboLiz2ImV3zzfhVQZjAngeHo394PanTvI='),
    (7, 'pF/OnsVVIEG52P87nHtECA==', 'mY9OWoLuDyjt5RilGVa7vNvx4EZdr2fuaLdF68tV1BM='),
    (8, 'yHJYL2KccUYDEicguxQV1Q==', '+5LVtyFWbyB9bidjbflY1QgOzGN3h4N9q3mVegxPxlI='),
    (9, 'adRlS3GZlp13z6MSdxBY7g==', 'fPm4xiATP0SOoAPpAydgyAbPRQS6muyyyGArWuuAA5o='),
    (10, 'NgIbtNW9NZcNEnGfWdTLFA==', 'tqhInGSO8WSAJ7zCaCyOtvMWU4ISOLz9kNA1Sc9WWys='),
    (11, 'Nmu7Ierl6h6s3J7SDFlUsg==', '8UuPwH+cxHNS/ZvwSCti56oODwBp95Amm25CC2GvWDE='),
    (12, 'NE9mTgwEv4ylbZGnhAIjWw==', 'nH079GmU08Z9iW72NyWDBQOa0x7p5vk9LX4yPvJEkaY='),
    (13, 'roLfJydtW2HEC2sNwyEKpQ==', 'GzhVdGQhAYgBWs3IBGkdi9jMNSMm+1MMNr5tyx0Eg7s='),
    (14, 'gnJBEMIkaJfxE42YnLxJIQ==', 'D8bC5ayjqkYYuRXEw0wqa/f6FUw5MIJ3d3lP6/acR3A='),
    (15, '397KtyDYXaNMsHRgkfyCjw==', 'jWUASjdtFYrn5SNQOtvr8q78j2/zHOYX4yX7AhWd++A='),
    (16, '9IcA1lQR+H0nkhx2fP5UCg==', 'E0EpAUTkO4ltXAMJaAgAn7VcABmNmeW21OojEAXUoxI='),
    (17, '179DHckwkOLLy2oxjjFhNg==', 'sX1gGVTu8DiPTl7iGWU/0e2jVjCtDGn5YHs6BeqG0ko='),
    (18, 'LH+qcBoIS9DMDdtYJkfBeA==', 'xee894AAXusfQKVz5vSWOX8AI3vtie6WVCe6fXNZsrE='),
    (19, 'HkII6TYJWVHgVe9F/GvN3w==', 'yyMhCStEmECfVXBUdgGl/3kzyBC+IAKaygBwD9zcliI='),
    (20, '1EPP/OWz5+3A6Wn95zL3qQ==', 'Z8jb17ql4rZJC8tUAfglVCq2LoNSy5qDY0ynXFaHJ3g='),
    (21, 'tQs4U8v6ovXEnrojVwwbSA==', 'abjRvlCG5XKSA5Iwmd8EL3YQTs7kWcVMiXD/L7wCWq8='),
    (22, 'aOplFpvADzqEKcD4Bk4aMQ==', '4bJi1tclc3C2SNWQBp2hdKOcuHB9r8tFKtDLw8yAcNA='),
    (23, '2ACLw3gR3/2uG+rsY/9L2w==', 'wHHKWnCfY1zL2P9314gezHvZOUvERW18hoeH+DHM2nc='),
    (24, 'KQP5SqICB7YYptYAk7ctRQ==', 'hEDM9k2HWpzk6q4OBthSsWld0j0sP/hzOJ92K3jVYIk='),
    (25, '70rMAs0giA/brpXeQMWctw==', 'r36ZZG2ZEo5ODix8gcNYZb1WlESd6Wx3/Gus0TYpuHA='),
    (26, '/f7GDc9HB3vLjgyYXBo+YA==', '3Lxbg4tVscCfvCR/xESKdLpyM3KY5U553LciRK8fepc='),
    (27, '1xoYRkG6Kt+rxRsx3pAY0w==', 'clfp0D4qb9fR0mHvqDMYoZCrlTu2SB6rHKZokAlN4ho='),
    (28, 'uzRSRBTr57fyjSgvTuA97Q==', 'kjWfa4h0E8s5rw5ZnuQX0TelJrIJvAxv7oQXryvyeuQ=');

    IF (SELECT COUNT(*) FROM @cred) <> 28
        THROW 56010, N'凭据表不是 28 条，停止写入。', 1;

    /* 5. 一次性插入 28 个账号 */
    INSERT INTO dbo.sys_user
        (username, password_hash, password_salt, real_name,
         role_code, org_id, elder_id, caregiver_id, user_status)
    SELECT
        a.username,
        c.password_hash,
        c.password_salt,
        a.real_name,
        a.role_code,
        a.org_id,
        a.elder_id,
        a.caregiver_id,
        N'正常'
    FROM @account AS a
    INNER JOIN @cred AS c ON c.seq = a.seq;

    IF @@ROWCOUNT <> 28
        THROW 56011, N'实际插入账号数不是 28，回滚。', 1;

    COMMIT TRANSACTION;

    SELECT role_code, COUNT(*) AS account_count
    FROM dbo.sys_user
    GROUP BY role_code
    ORDER BY role_code;

    PRINT N'B3 28 个正式联调账号初始化完成。';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
