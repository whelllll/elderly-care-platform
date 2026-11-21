/* ============================================================
   sys_user 基础测试账号：5 个
   前提：
     1. 已执行 09_sys_user.sql；
     2. 已执行成员1 的 03_member1_test_data.sql（service_org / elder_profile）。
   说明：
     - 不再写死 user_id 1..5，按 username 判重和关联；
     - org_id 按 service_org 的业务唯一键（org_name, org_address）查；
     - 演示密码统一为 Admin@123（PBKDF2-HMAC-SHA256，100000 次）；
     - 正式环境必须修改密码。
   ============================================================ */

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @org_comm INT, @org_mgr INT;

SELECT @org_comm = org_id
FROM dbo.service_org
WHERE org_name = N'阳光社区养老服务中心'
  AND org_address = N'阳光社区服务街道1号';

SELECT @org_mgr = org_id
FROM dbo.service_org
WHERE org_name = N'幸福居家养老服务站'
  AND org_address = N'幸福路88号';

IF @org_comm IS NULL OR @org_mgr IS NULL
BEGIN
    ;THROW 54001, N'缺少成员1 测试机构（阳光社区 / 幸福居家），请先执行成员1 的测试数据脚本。', 1;
END;

DECLARE @hash VARCHAR(256) = '+9w2RfX2uizSge3rQEsIPCnsyMt/TQGEqGYrcYxX38M=';
DECLARE @salt VARCHAR(64)  = 'Pxr9DkGQx1zOIQ3v+GuGEw==';

INSERT INTO dbo.sys_user
    (username, password_hash, password_salt, real_name,
     role_code, org_id, elder_id, caregiver_id, user_status)
SELECT
    v.username, @hash, @salt, v.real_name,
    v.role_code,
    CASE v.username
        WHEN N'comm_admin' THEN @org_comm
        WHEN N'org_mgr'    THEN @org_mgr
        ELSE NULL
    END,
    NULL, NULL, N'正常'
FROM
(
    VALUES
        (N'admin',      N'系统管理员', N'SYS_ADMIN'),
        (N'comm_admin', N'社区管理员', N'COMMUNITY_ADMIN'),
        (N'street_sup', N'街道监管员', N'STREET_SUPERVISOR'),
        (N'civil_sup',  N'民政监管员', N'CIVIL_SUPERVISOR'),
        (N'org_mgr',    N'机构负责人', N'ORG_MANAGER')
) AS v(username, real_name, role_code)
WHERE NOT EXISTS
(
    SELECT 1 FROM dbo.sys_user AS u WHERE u.username = v.username
);

SELECT user_id, username, real_name, role_code, org_id, elder_id, caregiver_id, user_status
FROM dbo.sys_user
WHERE username IN (N'admin', N'comm_admin', N'street_sup', N'civil_sup', N'org_mgr')
ORDER BY username;
GO

PRINT N'sys_user 基础测试账号已准备（按 username 判重，不写死 user_id）。';
GO
