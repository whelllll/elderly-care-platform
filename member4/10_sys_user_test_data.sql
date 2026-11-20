/* ============================================================
   sys_user 基础测试账号：5 个，user_id 1..5
   前提：
     1. 已执行 09_sys_user.sql；
     2. 已执行成员1 的 03_member1_test_data.sql（service_org / elder_profile）。
   说明：
     - user_id 1..5 是本表自己的测试编号，不是其他模块的自增 ID；
     - org_id 不写死，按 service_org 的业务唯一键（org_name, org_address）查；
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

IF NOT EXISTS (SELECT 1 FROM dbo.sys_user WHERE user_id BETWEEN 1 AND 5)
BEGIN
    SET IDENTITY_INSERT dbo.sys_user ON;

    INSERT INTO dbo.sys_user
        (user_id, username, password_hash, password_salt, real_name,
         role_code, org_id, elder_id, caregiver_id, user_status)
    VALUES
        (1, N'admin',      N'+9w2RfX2uizSge3rQEsIPCnsyMt/TQGEqGYrcYxX38M=', N'Pxr9DkGQx1zOIQ3v+GuGEw==', N'系统管理员', N'SYS_ADMIN',          NULL,      NULL, NULL, N'正常'),
        (2, N'comm_admin', N'+9w2RfX2uizSge3rQEsIPCnsyMt/TQGEqGYrcYxX38M=', N'Pxr9DkGQx1zOIQ3v+GuGEw==', N'社区管理员', N'COMMUNITY_ADMIN',    @org_comm, NULL, NULL, N'正常'),
        (3, N'street_sup', N'+9w2RfX2uizSge3rQEsIPCnsyMt/TQGEqGYrcYxX38M=', N'Pxr9DkGQx1zOIQ3v+GuGEw==', N'街道监管员', N'STREET_SUPERVISOR',  NULL,      NULL, NULL, N'正常'),
        (4, N'civil_sup',  N'+9w2RfX2uizSge3rQEsIPCnsyMt/TQGEqGYrcYxX38M=', N'Pxr9DkGQx1zOIQ3v+GuGEw==', N'民政监管员', N'CIVIL_SUPERVISOR',   NULL,      NULL, NULL, N'正常'),
        (5, N'org_mgr',    N'+9w2RfX2uizSge3rQEsIPCnsyMt/TQGEqGYrcYxX38M=', N'Pxr9DkGQx1zOIQ3v+GuGEw==', N'机构负责人', N'ORG_MANAGER',        @org_mgr,  NULL, NULL, N'正常');

    SET IDENTITY_INSERT dbo.sys_user OFF;
END;

SELECT user_id, username, real_name, role_code, org_id, elder_id, caregiver_id, user_status
FROM dbo.sys_user
ORDER BY user_id;
GO

PRINT N'sys_user 基础测试账号已准备：user_id 1..5。';
GO
