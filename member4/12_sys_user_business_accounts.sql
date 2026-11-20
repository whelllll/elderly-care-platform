/* ============================================================
   sys_user 补充业务账号
   ------------------------------------------------------------
   目标：
     在 10 号脚本的 5 个基础账号之外，补充：
       - 护理员账号：关联 caregiver
       - 老人账号：关联 elder_profile
       - 家属账号：关联 elder_profile
       - 机构负责人账号：关联 service_org
       - 审核人员账号：社区/街道/民政
   原则：
     1. 不写死 elder_id、caregiver_id、org_id；
     2. 老人用 id_card_no（唯一业务键）关联；
     3. 机构用 (org_name, org_address)（成员1 的唯一业务键）关联；
     4. 护工从 caregiver 实际在岗记录中取，不写死 caregiver_id；
     5. 脚本可重复执行，已存在的 username / caregiver_id 会跳过；
        username 里的 caregiver_id/org_id 只用于登录名唯一，不是写死的外键值。
   前提：
     09_sys_user.sql、10_sys_user_test_data.sql 已执行；
     成员1 的 service_org / elder_profile 测试数据已导入；
     成员3 的 caregiver 测试数据已导入。
   ============================================================ */

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID(N'dbo.sys_user', N'U') IS NULL
BEGIN
    ;THROW 55001, N'缺少 dbo.sys_user，请先执行 09_sys_user.sql。', 1;
END;

IF OBJECT_ID(N'dbo.service_org', N'U') IS NULL
BEGIN
    ;THROW 55002, N'缺少 dbo.service_org，请先执行成员1 的建表脚本。', 1;
END;

IF OBJECT_ID(N'dbo.elder_profile', N'U') IS NULL
BEGIN
    ;THROW 55003, N'缺少 dbo.elder_profile，请先执行成员1 的建表脚本。', 1;
END;

IF OBJECT_ID(N'dbo.caregiver', N'U') IS NULL
BEGIN
    ;THROW 55004, N'缺少 dbo.caregiver，请先执行成员3 的建表脚本。', 1;
END;

/* 演示密码统一 Admin@123；正式环境请改 */
DECLARE @hash VARCHAR(256) = '+9w2RfX2uizSge3rQEsIPCnsyMt/TQGEqGYrcYxX38M=';
DECLARE @salt VARCHAR(64)  = 'Pxr9DkGQx1zOIQ3v+GuGEw==';

/* ------------------------------------------------------------
   1. 护理员账号：取在岗护工前 5 名
   ------------------------------------------------------------ */
;WITH cg AS
(
    SELECT TOP (5)
        c.caregiver_id,
        c.caregiver_name,
        c.org_id,
        N'caregiver_' + RIGHT('000' + CONVERT(VARCHAR(10), c.caregiver_id), 3) AS username
    FROM dbo.caregiver AS c
    WHERE c.employment_status = N'在岗'
    ORDER BY c.caregiver_name, c.caregiver_id
)
INSERT INTO dbo.sys_user
    (username, password_hash, password_salt, real_name,
     role_code, org_id, elder_id, caregiver_id, user_status)
SELECT
    cg.username, @hash, @salt, cg.caregiver_name,
    N'CAREGIVER', cg.org_id, NULL, cg.caregiver_id, N'正常'
FROM cg
WHERE NOT EXISTS
(
    SELECT 1
    FROM dbo.sys_user AS u
    WHERE u.username = cg.username
       OR u.caregiver_id = cg.caregiver_id
);

/* ------------------------------------------------------------
   2. 老人账号：按 id_card_no 取前 5 位老人
   ------------------------------------------------------------ */
;WITH e AS
(
    SELECT TOP (5)
        e.elder_id,
        e.elder_name,
        e.id_card_no,
        N'elder_' + e.id_card_no AS username
    FROM dbo.elder_profile AS e
    WHERE e.archive_status = N'正常'
    ORDER BY e.id_card_no
)
INSERT INTO dbo.sys_user
    (username, password_hash, password_salt, real_name,
     role_code, org_id, elder_id, caregiver_id, user_status)
SELECT
    e.username, @hash, @salt, e.elder_name,
    N'ELDER', NULL, e.elder_id, NULL, N'正常'
FROM e
WHERE NOT EXISTS
(
    SELECT 1 FROM dbo.sys_user AS u WHERE u.username = e.username
);

/* ------------------------------------------------------------
   3. 家属账号：同样 5 位老人，各配 1 个家属账号
   ------------------------------------------------------------ */
;WITH e AS
(
    SELECT TOP (5)
        e.elder_id,
        e.elder_name,
        e.id_card_no,
        N'family_' + e.id_card_no AS username,
        LEFT(e.elder_name + N'家属', 50) AS family_name
    FROM dbo.elder_profile AS e
    WHERE e.archive_status = N'正常'
    ORDER BY e.id_card_no
)
INSERT INTO dbo.sys_user
    (username, password_hash, password_salt, real_name,
     role_code, org_id, elder_id, caregiver_id, user_status)
SELECT
    e.username, @hash, @salt, e.family_name,
    N'FAMILY', NULL, e.elder_id, NULL, N'正常'
FROM e
WHERE NOT EXISTS
(
    SELECT 1 FROM dbo.sys_user AS u WHERE u.username = e.username
);

/* ------------------------------------------------------------
   4. 机构负责人账号：按机构名称取前 3 家正常机构
   ------------------------------------------------------------ */
;WITH o AS
(
    SELECT TOP (3)
        o.org_id,
        o.org_name,
        N'orgmgr_' + CONVERT(VARCHAR(10), o.org_id) AS username,
        LEFT(N'机构负责人_' + o.org_name, 50) AS manager_name
    FROM dbo.service_org AS o
    WHERE o.org_status = N'正常'
    ORDER BY o.org_name
)
INSERT INTO dbo.sys_user
    (username, password_hash, password_salt, real_name,
     role_code, org_id, elder_id, caregiver_id, user_status)
SELECT
    o.username, @hash, @salt, o.manager_name,
    N'ORG_MANAGER', o.org_id, NULL, NULL, N'正常'
FROM o
WHERE NOT EXISTS
(
    SELECT 1 FROM dbo.sys_user AS u WHERE u.username = o.username
);

/* ------------------------------------------------------------
   5. 社区审核人员：取第 2、3 家正常机构，各配 1 个社区管理员
   ------------------------------------------------------------ */
;WITH o AS
(
    SELECT
        o.org_id,
        o.org_name,
        N'comm_auditor_' + CONVERT(VARCHAR(10), o.org_id) AS username,
        LEFT(N'社区审核员_' + o.org_name, 50) AS auditor_name,
        ROW_NUMBER() OVER (ORDER BY o.org_name) AS rn
    FROM dbo.service_org AS o
    WHERE o.org_status = N'正常'
)
INSERT INTO dbo.sys_user
    (username, password_hash, password_salt, real_name,
     role_code, org_id, elder_id, caregiver_id, user_status)
SELECT
    o.username, @hash, @salt, o.auditor_name,
    N'COMMUNITY_ADMIN', o.org_id, NULL, NULL, N'正常'
FROM o
WHERE o.rn BETWEEN 2 AND 3
  AND NOT EXISTS
  (
      SELECT 1 FROM dbo.sys_user AS u WHERE u.username = o.username
  );

/* ------------------------------------------------------------
   6. 街道/民政审核人员：不绑定 service_org
   ------------------------------------------------------------ */
INSERT INTO dbo.sys_user
    (username, password_hash, password_salt, real_name,
     role_code, org_id, elder_id, caregiver_id, user_status)
SELECT
    v.username, @hash, @salt, v.real_name,
    v.role_code, NULL, NULL, NULL, N'正常'
FROM
(
    VALUES
        (N'street_auditor_02', N'街道审核员02', N'STREET_SUPERVISOR'),
        (N'civil_auditor_02',  N'民政审核员02', N'CIVIL_SUPERVISOR')
) AS v(username, real_name, role_code)
WHERE NOT EXISTS
(
    SELECT 1 FROM dbo.sys_user AS u WHERE u.username = v.username
);

/* ------------------------------------------------------------
   7. 汇总
   ------------------------------------------------------------ */
SELECT role_code, COUNT(*) AS account_count
FROM dbo.sys_user
GROUP BY role_code
ORDER BY role_code;

PRINT N'sys_user 补充业务账号已处理（已存在的会跳过）。';
GO
