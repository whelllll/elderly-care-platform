/* ============================================================
   B3 28 账号 + M4 自测脚本
   前提：已执行 09、13、01、02、04；未执行 10/12。
   输出：每项 PASS/FAIL；有 FAIL 时最后 THROW。
   ============================================================ */

SET NOCOUNT ON;

IF OBJECT_ID(N'dbo.sys_user', N'U') IS NULL
    THROW 57001, N'缺少 dbo.sys_user。', 1;

DECLARE @check TABLE
(
    check_name NVARCHAR(100) NOT NULL,
    actual     INT           NOT NULL,
    expected   INT           NOT NULL
);

INSERT INTO @check (check_name, actual, expected)
SELECT N'账号总数', COUNT(*), 28
FROM dbo.sys_user
UNION ALL
SELECT N'CAREGIVER 账号', COUNT(*), 20
FROM dbo.sys_user WHERE role_code = N'CAREGIVER'
UNION ALL
SELECT N'SYS_ADMIN 账号', COUNT(*), 1
FROM dbo.sys_user WHERE role_code = N'SYS_ADMIN'
UNION ALL
SELECT N'COMMUNITY_ADMIN 账号', COUNT(*), 1
FROM dbo.sys_user WHERE role_code = N'COMMUNITY_ADMIN'
UNION ALL
SELECT N'STREET_SUPERVISOR 账号', COUNT(*), 1
FROM dbo.sys_user WHERE role_code = N'STREET_SUPERVISOR'
UNION ALL
SELECT N'CIVIL_SUPERVISOR 账号', COUNT(*), 1
FROM dbo.sys_user WHERE role_code = N'CIVIL_SUPERVISOR'
UNION ALL
SELECT N'ORG_MANAGER 账号', COUNT(*), 2
FROM dbo.sys_user WHERE role_code = N'ORG_MANAGER'
UNION ALL
SELECT N'ORG_MANAGER 不同机构数', COUNT(DISTINCT org_id), 2
FROM dbo.sys_user WHERE role_code = N'ORG_MANAGER'
UNION ALL
SELECT N'ELDER 账号', COUNT(*), 1
FROM dbo.sys_user WHERE role_code = N'ELDER'
UNION ALL
SELECT N'FAMILY 账号', COUNT(*), 1
FROM dbo.sys_user WHERE role_code = N'FAMILY'
UNION ALL
SELECT N'ELDER/FAMILY 老人数', COUNT(DISTINCT elder_id), 1
FROM dbo.sys_user WHERE role_code IN (N'ELDER', N'FAMILY')
UNION ALL
SELECT N'独立盐数量', COUNT(DISTINCT password_salt), 28
FROM dbo.sys_user
UNION ALL
SELECT N'独立哈希数量', COUNT(DISTINCT password_hash), 28
FROM dbo.sys_user
UNION ALL
SELECT N'护工绑定有效数', COUNT(*), 20
FROM dbo.sys_user AS u
INNER JOIN dbo.caregiver AS c
    ON c.caregiver_id = u.caregiver_id
   AND c.org_id = u.org_id
WHERE u.role_code = N'CAREGIVER'
UNION ALL
SELECT N'护工绑定无效数', COUNT(*), 0
FROM dbo.sys_user AS u
WHERE u.role_code = N'CAREGIVER'
  AND NOT EXISTS
  (
      SELECT 1 FROM dbo.caregiver AS c
      WHERE c.caregiver_id = u.caregiver_id
        AND c.org_id = u.org_id
  )
UNION ALL
SELECT N'老人/家属绑定有效数', COUNT(*), 2
FROM dbo.sys_user AS u
INNER JOIN dbo.elder_profile AS e ON e.elder_id = u.elder_id
WHERE u.role_code IN (N'ELDER', N'FAMILY')
UNION ALL
SELECT N'机构管理员绑定有效数', COUNT(*), 2
FROM dbo.sys_user AS u
INNER JOIN dbo.service_org AS o ON o.org_id = u.org_id
WHERE u.role_code = N'ORG_MANAGER'
UNION ALL
SELECT N'社区管理员机构非空', COUNT(*), 1
FROM dbo.sys_user
WHERE role_code = N'COMMUNITY_ADMIN' AND org_id IS NOT NULL
UNION ALL
SELECT N'街道/民政绑人/机构数', COUNT(*), 0
FROM dbo.sys_user
WHERE role_code IN (N'STREET_SUPERVISOR', N'CIVIL_SUPERVISOR')
  AND (org_id IS NOT NULL OR elder_id IS NOT NULL OR caregiver_id IS NOT NULL)
UNION ALL
SELECT N'SYS_ADMIN 绑人/机构数', COUNT(*), 0
FROM dbo.sys_user
WHERE role_code = N'SYS_ADMIN'
  AND (org_id IS NOT NULL OR elder_id IS NOT NULL OR caregiver_id IS NOT NULL);

IF OBJECT_ID(N'dbo.monitor_device', N'U') IS NOT NULL
BEGIN
    INSERT INTO @check (check_name, actual, expected)
    SELECT N'M4TEST 设备数', COUNT(*), 20
    FROM dbo.monitor_device WHERE device_sn LIKE N'M4TEST-%'
    UNION ALL
    SELECT N'M4TEST 体征数', COUNT(*), 20
    FROM dbo.vital_sign AS v
    INNER JOIN dbo.monitor_device AS d ON d.device_id = v.device_id
    WHERE d.device_sn LIKE N'M4TEST-%'
    UNION ALL
    SELECT N'M4 事件数', COUNT(*), 20
    FROM dbo.emergency_event
    UNION ALL
    SELECT N'已闭环事件', COUNT(*), 8
    FROM dbo.emergency_event WHERE event_status = N'已闭环'
    UNION ALL
    SELECT N'处置中事件', COUNT(*), 4
    FROM dbo.emergency_event WHERE event_status = N'处置中'
    UNION ALL
    SELECT N'待响应事件', COUNT(*), 6
    FROM dbo.emergency_event WHERE event_status = N'待响应'
    UNION ALL
    SELECT N'已误报事件', COUNT(*), 2
    FROM dbo.emergency_event WHERE event_status = N'已误报'
    UNION ALL
    SELECT N'事件响应人角色越界数', COUNT(*), 0
    FROM dbo.emergency_event AS e
    INNER JOIN dbo.sys_user AS u ON u.user_id = e.responder_id
    WHERE u.role_code NOT IN (N'COMMUNITY_ADMIN', N'ORG_MANAGER', N'CAREGIVER');
END;

IF OBJECT_ID(N'dbo.v_open_emergency', N'V') IS NOT NULL
BEGIN
    INSERT INTO @check (check_name, actual, expected)
    SELECT N'M4 视图数', COUNT(*), 3
    FROM sys.views
    WHERE name IN (N'v_elder_device_active', N'v_elder_latest_vital', N'v_open_emergency')
    UNION ALL
    SELECT N'M4 存储过程数', COUNT(*), 3
    FROM sys.procedures
    WHERE name IN (N'sp_raise_emergency', N'sp_accept_emergency', N'sp_close_emergency');
END;

SELECT
    check_name,
    actual,
    expected,
    CASE WHEN actual = expected THEN N'PASS' ELSE N'FAIL' END AS status
FROM @check
ORDER BY check_name;

IF EXISTS (SELECT 1 FROM @check WHERE actual <> expected)
    THROW 57002, N'B3/M4 自测存在 FAIL，请查看上方结果并修正后重跑。', 1;

PRINT N'B3 28 账号 + M4 自测全部 PASS。';
GO
