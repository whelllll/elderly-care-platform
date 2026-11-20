/* ============================================================
   sys_user 测试账号：5 个，user_id 1..5
   前提：
     1. 已执行 09_sys_user.sql；
     2. 已执行成员1 的 03_member1_test_data.sql（service_org 有 1、2 号机构）。
   说明：
     - 演示密码统一为 Admin@123（PBKDF2-HMAC-SHA256，100000 次）；
     - 正式环境必须修改密码；
     - 这 5 个账号用于满足 04_test_data.sql 的 responder_id 1..5。
   ============================================================ */

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF (SELECT COUNT(*) FROM dbo.service_org WHERE org_id IN (1, 2)) < 2
BEGIN
    ;THROW 54001, N'缺少 service_org 1、2 号机构，请先执行成员1 的测试数据脚本。', 1;
END;

IF NOT EXISTS (SELECT 1 FROM dbo.sys_user WHERE user_id BETWEEN 1 AND 5)
BEGIN
    SET IDENTITY_INSERT dbo.sys_user ON;

    INSERT INTO dbo.sys_user
        (user_id, username, password_hash, password_salt, real_name,
         role_code, org_id, elder_id, caregiver_id, user_status)
    VALUES
        (1, N'admin',       N'+9w2RfX2uizSge3rQEsIPCnsyMt/TQGEqGYrcYxX38M=', N'Pxr9DkGQx1zOIQ3v+GuGEw==', N'系统管理员',   N'SYS_ADMIN',          NULL, NULL, NULL, N'正常'),
        (2, N'comm_admin',  N'+9w2RfX2uizSge3rQEsIPCnsyMt/TQGEqGYrcYxX38M=', N'Pxr9DkGQx1zOIQ3v+GuGEw==', N'社区管理员',   N'COMMUNITY_ADMIN',    1,    NULL, NULL, N'正常'),
        (3, N'street_sup',  N'+9w2RfX2uizSge3rQEsIPCnsyMt/TQGEqGYrcYxX38M=', N'Pxr9DkGQx1zOIQ3v+GuGEw==', N'街道监管员',   N'STREET_SUPERVISOR',  NULL, NULL, NULL, N'正常'),
        (4, N'civil_sup',   N'+9w2RfX2uizSge3rQEsIPCnsyMt/TQGEqGYrcYxX38M=', N'Pxr9DkGQx1zOIQ3v+GuGEw==', N'民政监管员',   N'CIVIL_SUPERVISOR',   NULL, NULL, NULL, N'正常'),
        (5, N'org_mgr',     N'+9w2RfX2uizSge3rQEsIPCnsyMt/TQGEqGYrcYxX38M=', N'Pxr9DkGQx1zOIQ3v+GuGEw==', N'机构负责人',   N'ORG_MANAGER',        2,    NULL, NULL, N'正常');

    SET IDENTITY_INSERT dbo.sys_user OFF;
END;

SELECT user_id, username, real_name, role_code, org_id, elder_id, caregiver_id, user_status
FROM dbo.sys_user
ORDER BY user_id;
GO

PRINT N'sys_user 测试账号已准备：user_id 1..5。';
GO
