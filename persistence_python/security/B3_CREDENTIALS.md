# B3凭据准备与授权后验收

本模块复用`password.hash_password()`（返回hash、salt）、`accounts.secure_b3_accounts()`、`LoginService`和`SessionStore`。算法保持PBKDF2-HMAC-SHA256、100000轮、16字节随机盐和标准Base64。成员4SQL及成员5接口不在本次修改范围。

## 本地凭据文件

`credentials.py`使用`secrets.token_urlsafe(24)`生成28个独立密码，以Windows当前用户DPAPI加密后保存。没有明文降级、密码输出或覆盖已有文件的选项。文件必须位于Git仓库之外，读取需使用创建文件的Windows用户。复制密文到另一账号不能代替凭据交付；应保留该用户的受保护备份。

本次已准备的文件：`C:/Users/65770/Documents/Codex/credentials/b3-28-20261123.dpapi`。该文件仅绑定模板中的28个`password_env`槽位，尚未绑定或更新实际数据库账号。确认真实用户名时保留各槽位与角色的对应关系，不随意交换`password_env`。盐及哈希在获授权实际改密时由现有函数重新生成，明文仅在进程内解密使用。

若准备另一个独立环境，使用新文件路径（不要覆盖上述文件）：

```powershell
python -B -m persistence_python.security.credentials --manifest persistence_python/security/b3-accounts.template.json --output C:/secure-config/new-b3.dpapi
```

## 仍需确认的信息

必须先确认SQL Server实例、完整测试数据库名、允许维护的28个账号及维护窗口，取得读取身份、更新凭据和登录验收的明确授权。本轮没有连接数据库。

从获授权目标库只读核对实际`username`、`user_id`、`role_code`、`org_id`、`elder_id`、`caregiver_id`及账号状态，将`security/b3-accounts.template.json`复制到仓库外后填写真实值。模板中的占位用户名、null主键不能用于更新或验收。28项角色必须为20护工、2不同机构负责人及其余6种角色各1，老人/家属绑定同一老人。

连接串通过现有`ELDERCARE_DATABASE_URL`提供；维护管理员当前密码通过受控进程环境`B3_ADMIN_PASSWORD`提供，不写命令行、清单或报告。不得把数据库连接串或密码发到普通日志。

## 授权后的执行顺序

以下为待授权命令，本轮未执行。`实际测试库名`必须替换为人工确认的完整库名，显式授权参数不能代替组织或用户的授权。

1. 停止并发登录和账号维护，先离线检查完整身份清单与密文凭据。

```powershell
python -B -m persistence_python.security.accounts --manifest C:/secure-config/b3-accounts.json --credential-file C:/Users/65770/Documents/Codex/credentials/b3-28-20261123.dpapi --check-config
```

2. 获得写入授权后运行现有改密入口。工具核对实际数据库名、只读认证维护管理员，在一个事务内锁定账号范围、检查sys_user总数恰好28、角色/身份契约和实际expected，再生成及检查独立盐/哈希，只更新四个凭据/更新时间字段。任何异常由原数据库工作单元回滚。管理员维护认证不更新其登录时间、失败次数或状态。此入口不会自动解锁或启用账号。

```powershell
python -B -m persistence_python.security.accounts --manifest C:/secure-config/b3-accounts.json --credential-file C:/Users/65770/Documents/Codex/credentials/b3-28-20261123.dpapi --apply --admin admin --expected-database 实际测试库名 --authorize-test-update
```

3. 配置正常B3启动门禁并验收。成功登录会正常清零失败计数并更新登录时间，因此也需要明确授权。

```powershell
$env:ELDERCARE_PROFILE = 'B3'
$env:ELDERCARE_B3_ACCOUNT_MANIFEST = 'C:/secure-config/b3-accounts.json'
python -B -m persistence_python.security.verify_b3 --manifest C:/secure-config/b3-accounts.json --credential-file C:/Users/65770/Documents/Codex/credentials/b3-28-20261123.dpapi --expected-database 实际测试库名 --report C:/secure-config/b3-login-results.json
```

报告逐项记录用户名、角色、登录/Session创建、身份、退出和固定失败原因码；汇总账号数、登录成功/失败数、身份正确/错误/未检查数及退出成功数。预检失败不试登录，单列未执行数量；运行中单个账号失败仍记录后续账号，失败时命令返回非零。报告不包含密码、盐、哈希、令牌或底层异常文本；报告文件拒绝覆盖。

改密后所有旧Session失效。不要盲目重跑apply，它会再次生成盐、变更凭据版本。结束后清除维护密码的进程环境，保留密文文件供后续验收。

## 测试边界

离线测试覆盖随机性、DPAPI往返/篡改、完整身份及总数检查、重复盐/哈希拒绝、仅更新四个字段、失败回滚协议、脱敏逐账号报告及退出校验。内存事务/查询测试双不证明真实SQL Server锁或回滚行为；真实数据库改密、真实账号登录及服务器事务验收仍须授权后执行。历史131项测试通过记录不能当作本次数据库验收结果。

2026-11-23最终完整离线回归：收集212项，145通过、0失败、67项SQL Server测试跳过，28.26秒，真实数据库连接尝试0次。B3相关四个测试文件此前针对性回归为102通过、0失败、6跳过；之后新增的SQL回滚测试已纳入最终跳过统计。45个Python文件语法检查及`git diff --check`通过。首轮4项报告测试因内存查询测试双缺少user_id支持失败，补齐后通过；模板凭据准备也已单独覆盖，模板仍不能用于数据库更新。

最终测试报告：`C:/Users/65770/Documents/Codex/work/m2-b3-credentials-20261123-implementation/pytest-complete.xml`。密文文件离线自检证据：同目录`credential-check.json`，确认28个密码、盐和哈希互不相同，28个正确密码验证通过、28个错误密码被拒绝、文件不包含明文密码。自检盐和哈希仅在内存使用；实际改密时重新生成。上述结果不代表实际B3账号已改密或真实登录通过。
