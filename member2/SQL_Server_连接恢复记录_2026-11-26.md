# SQL Server 连接恢复记录（2026-11-26）

## 当前结论

已从当前 Codex 执行会话成功连接本机 SQL Server 隔离测试库 `Codex_Persistence_20261121_162302`。连接方式是通过平台受控的宿主身份授权运行只读命令；不需要把密码或连接字符串复制到聊天中。

验证结果：

- `sqlcmd` 在宿主身份下成功执行受数据库名保护的 `SELECT DB_NAME()`，返回 `Codex_Persistence_20261121_162302`。
- ODBC Driver 18 只读连接成功，查询同一数据库名；连接加密保持启用。
- 两项 DPAPI 测试在宿主身份下通过：`2 passed in 0.15s`。
- 本次连接恢复只执行了只读查询和DPAPI测试，没有写入数据库、修改系统TLS设置或业务代码。

## 为什么普通执行失败

当前默认受限沙箱进程的Windows主体是 `无欲\CodexSandboxOffline`，SID末段为 `1003`。它虽然显示 `USERPROFILE=C:\Users\65770`，但并没有交互用户的Windows集成认证票据或DPAPI用户密钥。因此：

- `sqlcmd -E` / Windows集成认证在默认沙箱中失败，ODBC/SChannel提示安全包中没有凭据。
- 依赖当前Windows用户DPAPI的测试在默认沙箱中失败。

授权后的宿主执行主体为 `无欲\65770`，SID末段为 `1001`。PowerShell版本、ODBC Driver 18、Python路径和用户目录与默认环境相同，关键差异是Windows安全主体及SID。数据库授权和DPAPI密钥都属于实际登录用户，不能由相同的用户目录字符串替代。

## 后续连接步骤

1. 在 `functions.exec` 中调用 `exec_command`，设置 `sandbox_permissions: "require_escalated"`，并说明用途是连接指定的隔离测试库执行只读核验或已授权的测试。
2. 命令先校验精确数据库名及 `Codex_Persistence_` 前缀，再连接。不要在未校验目标库前执行脚本。
3. 使用本机共享内存目标 `lpc:.` 和当前用户集成认证。示例只读探针：

```powershell
$db = 'Codex_Persistence_20261121_162302'
$sql = @"
SET NOCOUNT ON;
IF DB_NAME() <> N'$db' OR DB_NAME() NOT LIKE N'Codex_Persistence[_]%'
    THROW 53000, N'Unexpected database; stop.', 1;
SELECT DB_NAME() AS database_name;
"@
sqlcmd -S 'lpc:.' -E -C -d $db -b -Q $sql
if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed: $LASTEXITCODE" }
```

4. Python/ODBC连接用Windows集成认证，保持加密启用。当前本机SQL Server使用自签名证书，因此只在该本机连接上信任服务器证书；不设置全局TLS选项、不关闭传输加密：

```text
DRIVER={ODBC Driver 18 for SQL Server};SERVER=lpc:.;DATABASE=Codex_Persistence_20261121_162302;Trusted_Connection=yes;Encrypt=yes;TrustServerCertificate=yes
```

5. DPAPI相关操作也必须在宿主身份授权上下文运行，才能访问 `无欲\65770` 的当前用户DPAPI密钥。不要把DPAPI密文复制到其他Windows SID下解密，也不要改为明文存储。
6. 写入操作仍须针对确认过的 `Codex_Persistence_` 隔离库，并按用户要求先确认会提交的种子数据计划。正式 `Data` 不属于此授权范围。

## 11月22日历史对照

`member2/2026-11-22_后端开发与联调说明.md`记载了相同隔离库、ODBC Driver 18、Windows集成认证、`sqlcmd -C`连接成功及160项真实SQL Server回归通过。历史材料没有保存当时的 `whoami` 或SID，因此无法从历史报告直接证明当时的具体Windows令牌；本次测试已证明宿主授权上下文能恢复连接并通过DPAPI测试。

## 禁止事项与结果记录

- 不在聊天、Markdown或命令历史中保存密码、令牌或连接密钥。
- 不修改SQL Server全局TLS、安全策略或认证模式；不为了绕过身份差异而启用共享密码登录。
- 不连接或写入正式 `Data`，不运行B1/B2正式初始化脚本。
- 每次记录数据库名、执行身份类型（不记录凭据）、只读/写入范围、命令、退出码及实际测试结果。
- 成员5种子数据、T9/T12/T13和并发专项仍按联调记录里的数据准备方案执行；本记录只说明连接恢复方式，不代表那些验收已经通过。

详细环境比较与恢复证据见[2026-11-26联调记录第19节](2026-11-26_member2_integration.md#19-2026-11-26-windows-identity-comparison-and-connection-recovery)。
