# 2026-11-26 成员2后端与持久层联调记录

## 1. 版本基线

- 开发分支：`feature/member2-b3-credentials`
- 当前 HEAD：`ac99bae`（已合并最新 `origin/main`）
- 成员2既有提交：`98b6991`、`25acab9`。
- 成员5基线：`6afb979`，最新修订：`43c466a`。
- 成员1 B1/B2 独立测试交付：`f1830e1`。
- 开始本轮工作前工作区干净，本地分支领先远程3个提交。
- 不直接合并 main，不未经确认 push，不写入正式 Data 库。

## 2. 已确认业务契约

### 2.1 审核任务归属与指派

| 审核节点 | 允许发起指派的角色 | 被指派人角色 |
| --- | --- | --- |
| 待社区初审 | COMMUNITY_ADMIN | COMMUNITY_ADMIN |
| 街道复审中 | STREET_SUPERVISOR | STREET_SUPERVISOR |

- 待办查询及实际审核写入口均须验证节点角色和任务归属；`current_auditor_id` 为 NULL 或等于本人时可审核，属于他人时拒绝。
- 同节点有权人员可以覆盖原指派；行锁互斥，以最后一次成功指派为准。
- 被指派人必须存在、角色匹配且 `user_status=N'正常'`；停用或锁定账号由 SQL 拒绝（52176）。
- 发起人节点角色校验由 Python 负责，不匹配返回 403；被指派人由 `usp_M5_AssignAuditor` 校验。
- `usp_M5_AuditAdvance` 在节点流转时原子更新状态并清空 `current_auditor_id`，实际审核人记录于 `subsidy_audit_log.auditor_id`。Python 不自行回写或清空该字段。

### 2.2 整改提交与历史追溯

- 允许提交状态：待整改、整改中、逾期未改、复查不通过。
- 复查不通过可在同一张整改单中返工并重新提交；提交后转待复查并更新提交时间。
- 复查通过前原有限制保持；通过后仅按实际剩余限制记录判定是否解除接单限制。
- Submit/Review 使用统一锁协议，加锁后 UPDLOCK 重读并校验状态，避免使用过期状态。
- 群内新增验收要求：必须保留每次复查结果的完整历史，不得由新一轮复查覆盖旧结果。需核对现有表结构及过程是否支持；若不支持，记录证据并与成员5确认替代方案，未经确认不改表。

## 3. 已完成与今日待办

- [x] 确认成员5业务规则并合并最新 main 到开发分支。
- [x] 成员2既有审核归属、指派权限和 B3 凭据工具已提交功能分支（此前仅离线回归）。
- [x] 阅读最新 SQL、Python DAO、权限层、存储过程包装和测试并核对契约；仅修复整改提交入口与 SQL 过程不一致。
- [x] 静态核对审核归属三态、节点角色、覆盖指派、账号状态拒绝码及节点流转日志；真实库验收待完成。
- [x] 静态核对整改四种提交状态、失败复查后重新提交、重复提交拒绝和限制同步；历史追溯不足已记录待确认。
- [ ] 检查 SQL T9/T12/T13 和过程存在性验收；区分成员5已报告结果与本轮实测结果。
- [ ] 在明确的独立 SQL Server 测试库执行完整接口回归，记录通过、失败、跳过及原因。
- [ ] 在独立测试库完成双会话并发验收：审核归属/节点指派互斥、整改 Submit/Review 状态一致性；与成员5协调联合验收。
- [x] 整理源码版本、历史测试库名称、执行命令、测试结果、未通过事项和修改文件清单；详见下文。
- [ ] 完成验收后准备本地提交及 PR；未经确认不推送或合并。

## 4. B1/B2/B3 与写入边界

- 成员1已报告 B1/B2 独立测试通过并提交脚本、预检、核验及报告；不能据此认定正式 Data 库已获写入授权，也不得重复执行其已完成的写入脚本。
- B3 已完成 28 套独立随机凭据本地加密保存和逐账号验收工具；正式密码更新、真实登录验收尚未执行。
- 20 条专用订单工具已准备，正式订单写入仍待 B1/B2 验收及统一授权。
- 不输出或提交明文密码、盐值、密钥等敏感材料；不把离线测试或跳过测试当作真实 SQL Server 验收通过。
- 成员1缺少存储过程或触发器的问题由成员1负责，本轮不代改。


## 5. 2026-11-26 ?????????

### 5.1 ???????

- ???????????? `audit_stage` / `require_audit_task` ?????? `current_auditor_id` ???????????????????????????????Python ?????????????5??????????????
- ????????????? `user_status=N'??'` ? `usp_M5_AssignAuditor` ???SQL ??/??????? 52176?`usp_M5_AuditAdvance` ??????????????? `subsidy_audit_log`?Python ??????????
- ?? SQL ?? `usp_M5_SubmitRectification` ??????? `UPDLOCK` ??????????????????????????????????????????????????? Python ???????????? ORM ????? SQL ???????????????????????
- ?? `Member5DAO.submit_rectification` ???? `usp_M5_SubmitRectification`???????? `submit_note` ??? `rectify_status` ??????????????????????? SQL ?????/??/???????

### 5.2 ??????????????

- `member5/01_member5_tables.sql` ? `dbo.rectification` ???? `review_time`?`reviewer_id`?`review_result`?`remark` ???????????????????
- `member5/06_member5_procedures.sql` ? `usp_M5_ReviewRectification` ??????????? `review_result`?`review_time`?`reviewer_id`???????????????`usp_M5_SubmitRectification` ??????????? `remark`??? 200 ?????????????????????????????
- ????????????????????????????????? SQL ??????????5????????????????????????????????????????

### 5.3 ??????

- ?????? `ELDERCARE_TEST_DATABASE_URL`?pytest ?? `%TEMP%` ?????? basetemp????? `pytest-of-65770` ??????????????????? Git ????
- ?????`python -B -m pytest persistence_python -q --tb=short -p no:cacheprovider --basetemp <????????> -k "test_submit_rectification_uses_sql_contract_and_returns_status or test_manifest_preflight_rejects_invalid_configuration or test_assignment_wrapper_checks_locked_stage_and_preserves_output"`??? **14 passed?199 deselected**?
- ???????????**144 passed?67 skipped?2 failed?42.43 ?**?67 ??????????????????? `test_dpapi_roundtrip_no_plaintext_and_no_overwrite` ? `test_tampered_vault_and_wrong_slots_fail_closed`?????? vault ?? Git ????????? `security/credentials.py::_dpapi`?Windows DPAPI ?????????????????????????????????????????????????????
- ?????????? DPAPI ??????????**144 passed?67 skipped?2 deselected?42.23 ?**????????? DPAPI ?????
- pytest ???? basetemp ?? `%TEMP%\pytest-of-65770` ?? `PermissionError`??????????????????????????????????????????????????

### 5.4 SQL Server ?????????

- ????????????? `Codex_Persistence_20261121_162302`?Windows ??????????? `ELDERCARE_TEST_DATABASE_URL` ???????? `Codex_Persistence_` ???`persistence_python/conftest.py` ??????????????? Data ???????????
- ??????? `ELDERCARE_TEST_DATABASE_URL`??????????????????????????????????????5 SQL ???????
- ??????????????????????`lpc:.`?`localhost`??ODBC Driver 18?17??? SQL Server ???? `sqlcmd -C` ????????? SSL ??/????????????????????????? Data ????? B1/B2 ?????? B3 ??????????
- ??????????????????5 SQL T9/T12/T13 ??????????Python ?? SQL Server ????????????**???**?????????????????????????? `MSSQLSERVER` ?????????????????????????

### 5.5 ??????

- ?????`persistence_python/member5_dao.py`?`persistence_python/procedures.py`?`persistence_python/test_audit_tasks.py`???? Markdown?
- ??????? `feature/member2-b3-credentials`???? HEAD `ac99bae`???? commit?push ????
- ???????? Windows DPAPI ??????? vault ?????/????? `Codex_Persistence_` ?? SQL Server ???????????5?????????????????T9/T12/T13 ????????????????????5???
## 5. 2026-11-26 ?????????

### 5.1 ???????

- ???????????? `audit_stage` / `require_audit_task` ?????? `current_auditor_id` ???????????????????????????????Python ?????????????5??????????????
- ????????????? `user_status=N'??'` ? `usp_M5_AssignAuditor` ???SQL ??/??????? 52176?`usp_M5_AuditAdvance` ??????????????? `subsidy_audit_log`?Python ??????????
- ?? SQL ?? `usp_M5_SubmitRectification` ??????? `UPDLOCK` ??????????????????????????????????????????????????? Python ???????????? ORM ????? SQL ???????????????????????
- ?? `Member5DAO.submit_rectification` ???? `usp_M5_SubmitRectification`???????? `submit_note` ??? `rectify_status` ??????????????????????? SQL ?????/??/???????

### 5.2 ??????????????

- `member5/01_member5_tables.sql` ? `dbo.rectification` ???? `review_time`?`reviewer_id`?`review_result`?`remark` ???????????????????
- `member5/06_member5_procedures.sql` ? `usp_M5_ReviewRectification` ??????????? `review_result`?`review_time`?`reviewer_id`???????????????`usp_M5_SubmitRectification` ??????????? `remark`??? 200 ?????????????????????????????
- ????????????????????????????????? SQL ??????????5????????????????????????????????????????

### 5.3 ??????

- ?????? `ELDERCARE_TEST_DATABASE_URL`?pytest ?? `%TEMP%` ?????? basetemp????? `pytest-of-65770` ??????????????????? Git ????
- ?????`python -B -m pytest persistence_python -q --tb=short -p no:cacheprovider --basetemp <????????> -k "test_submit_rectification_uses_sql_contract_and_returns_status or test_manifest_preflight_rejects_invalid_configuration or test_assignment_wrapper_checks_locked_stage_and_preserves_output"`??? **14 passed?199 deselected**?
- ???????????**144 passed?67 skipped?2 failed?42.43 ?**?67 ??????????????????? `test_dpapi_roundtrip_no_plaintext_and_no_overwrite` ? `test_tampered_vault_and_wrong_slots_fail_closed`?????? vault ?? Git ????????? `security/credentials.py::_dpapi`?Windows DPAPI ?????????????????????????????????????????????????????
- ?????????? DPAPI ??????????**144 passed?67 skipped?2 deselected?42.23 ?**????????? DPAPI ?????
- pytest ???? basetemp ?? `%TEMP%\pytest-of-65770` ?? `PermissionError`??????????????????????????????????????????????????

### 5.4 SQL Server ?????????

- ????????????? `Codex_Persistence_20261121_162302`?Windows ??????????? `ELDERCARE_TEST_DATABASE_URL` ???????? `Codex_Persistence_` ???`persistence_python/conftest.py` ??????????????? Data ???????????
- ??????? `ELDERCARE_TEST_DATABASE_URL`??????????????????????????????????????5 SQL ???????
- ??????????????????????`lpc:.`?`localhost`??ODBC Driver 18?17??? SQL Server ???? `sqlcmd -C` ????????? SSL ??/????????????????????????? Data ????? B1/B2 ?????? B3 ??????????
- ??????????????????5 SQL T9/T12/T13 ??????????Python ?? SQL Server ????????????**???**?????????????????????????? `MSSQLSERVER` ?????????????????????????

### 5.5 ??????

- ?????`persistence_python/member5_dao.py`?`persistence_python/procedures.py`?`persistence_python/test_audit_tasks.py`???? Markdown?
- ??????? `feature/member2-b3-credentials`???? HEAD `ac99bae`???? commit?push ????
- ???????? Windows DPAPI ??????? vault ?????/????? `Codex_Persistence_` ?? SQL Server ???????????5?????????????????T9/T12/T13 ????????????????????5???\n\n## 5. 2026-11-26 本轮联调与测试记录

### 5.1 核对与修复

- 审核待办及写入口按节点角色和 `current_auditor_id` 三态校验；本人未指派/本人指派可办，他人指派拒绝。同节点角色允许重指派，SQL 行锁决定最后成功结果。被指派人角色及 `user_status=N'正常'` 由 `usp_M5_AssignAuditor` 校验（停用/锁定 52176）。`usp_M5_AuditAdvance` 原子流转、清空当前指派并写入 `subsidy_audit_log`，Python 不自行改指派字段。
- 整改提交原先由 Python ORM 直接更新状态和时间，绕过 SQL 过程的统一锁和加锁后状态重读。现改为调用 `usp_M5_SubmitRectification`，白名单增加 `submit_note` 输入和 `rectify_status` 输出，并新增契约测试。该 SQL 过程覆盖待整改、整改中、逾期未改、复查不通过状态，保持限制标志，重复/错误状态由 SQL 拒绝。

### 5.2 整改复查历史（跨成员待确认）

- `member5/01_member5_tables.sql` 的 `dbo.rectification` 只有单组 `review_time`、`reviewer_id`、`review_result`、`remark`，没有逐轮历史表。
- `member5/06_member5_procedures.sql` 的 `usp_M5_ReviewRectification` 每轮覆盖同一行的结果、时间和复查人；新一轮会覆盖旧结果。提交说明追加到同一 `remark`（最多 200 字），不能结构化追溯每轮复查信息。
- 当前结构不能完整满足复查历史追溯。本轮未改表或过程。建议成员5确认复查历史表及由复查过程同事务追加记录的方案，或确认替代方案后再实施。

### 5.3 离线测试

- 未设置 `ELDERCARE_TEST_DATABASE_URL`。pytest 使用 `%TEMP%` 下唯一 basetemp，解决默认 `pytest-of-65770` 的目录权限问题，并使 vault 临时文件位于 Git 仓库外。
- 定向命令：`python -B -m pytest persistence_python -q --tb=short -p no:cacheprovider --basetemp <唯一系统临时目录> -k "test_submit_rectification_uses_sql_contract_and_returns_status or test_manifest_preflight_rejects_invalid_configuration or test_assignment_wrapper_checks_locked_stage_and_preserves_output"`；**14 passed、199 deselected**。
- 全量离线套件：**144 passed、67 skipped、2 failed（42.43 秒）**。67 项因未设置隔离库而跳过。两项失败为 `test_dpapi_roundtrip_no_plaintext_and_no_overwrite`、`test_tampered_vault_and_wrong_slots_fail_closed`；失败在 `security/credentials.py::_dpapi`，当前 Windows 执行环境的 DPAPI 返回“凭据加解密失败”。临时 vault 已在 Git 仓库外，因此不是路径保护失败；属于环境能力问题，未改测试断言或绕过保护。
- 排除上述两项 DPAPI 环境依赖用例后复跑：**144 passed、67 skipped、2 deselected（42.23 秒）**，不代表 DPAPI 用例通过。全量统计保留为 2 failed。
- 测试临时目录在执行后清理。修改代码的定向测试及全量其余离线用例均通过。

### 5.4 独立 SQL Server 测试库

- 项目历史记录给出的隔离库名为 `Codex_Persistence_20261121_162302`，Windows 集成认证；测试连接要求显式配置 `ELDERCARE_TEST_DATABASE_URL`，且 `persistence_python/conftest.py` 在初始化前限制库名必须为 `Codex_Persistence_` 前缀。历史记录不能证明该库当前仍存在或已部署最新成员5 SQL。
- 本轮连接变量未配置。对上述历史库、本机端点 `lpc:.` / `localhost` 做只读探测，ODBC Driver 18、17、旧版 SQL Server 驱动及 `sqlcmd -C` 均因 SSL 凭据/客户端加密错误而在连接建立阶段失败，未确认数据库身份。本机 `MSSQLSERVER` 服务运行不足以证明目标为隔离库。
- 本轮未连接或写入正式 Data 库，未执行 B1/B2 初始化、正式 B3 改密或正式订单写入。成员5 T9/T12/T13、真实 SQL Server 全量回归及双会话并发验收均**未执行**，不能以历史结果代替。

### 5.5 修改与未完成事项

- 修改文件：`persistence_python/member5_dao.py`、`persistence_python/procedures.py`、`persistence_python/test_audit_tasks.py`、本 Markdown。
- 分支 `feature/member2-b3-credentials`，开始时 HEAD `ac99bae`；未 commit、push 或合并。
- 未完成：在 DPAPI 可用的 Windows 上下文重跑两项测试；恢复明确的 `Codex_Persistence_` 测试库连接并核对库名/成员5对象版本后执行数据库回归、T9/T12/T13 和双会话验收；复查历史结构待成员5确认。

## 6. 2026-11-26 follow-up: restoring the independent test environment

### Read-only findings

- Historical successful setup in `member2/2026-11-22_后端开发与联调说明.md` used the local shared-memory SQL Server endpoint `lpc:.`, database `Codex_Persistence_20261121_162302`, Windows integrated authentication, ODBC Driver 18, and `Encrypt=no`. Historical report records 160 passing tests after deploying member5 SQL commit `266ae3a`; this is historical evidence, not current verification.
- `persistence_python/conftest.py` requires explicit `ELDERCARE_TEST_DATABASE_URL` and rejects databases without the `Codex_Persistence_` prefix before `Database.initialize`. No test URL is currently configured. README instructions show a generic localhost URL; the more specific historical shared-memory configuration is the relevant recovery reference.
- Local service enumeration found default instance `MSSQLSERVER` running and SQLBrowser stopped. This does not establish that the historical database exists or contains the current SQL version.
- Repeated read-only connection attempts to only the historical prefixed database, using `lpc:.` and `localhost`, failed before database authentication. ODBC 18, ODBC 17, legacy SQL Server ODBC, and `sqlcmd -C` returned SSL credential/client-encryption negotiation errors. No database identity or schema version was obtained. No connection was made to the formal Data database.
- Current connection process runs as Windows user `65770`; profile paths exist, but the process is non-interactive. This alone does not identify the TLS cause. The observed SSL/SChannel error indicates no usable credential for the TLS handshake in this execution context; server-side force-encryption/certificate settings and SQL Server error logs remain unverified. No security setting was lowered or bypassed.

### DPAPI recheck

- Ran only `test_dpapi_roundtrip_no_plaintext_and_no_overwrite` and `test_tampered_vault_and_wrong_slots_fail_closed`, with a unique `%TEMP%` basetemp outside the repository. Result: **2 failed, 29 deselected**. Both fail in `security/credentials.py::_dpapi` with the existing safe error requesting the creating Windows user. Vault path validation passed; the failure reproduces at the Windows DPAPI call. This supports an execution-context limitation, but does not prove DPAPI works in an interactive user session.

### Status and next steps

- Completed: historical configuration/documentation review; endpoint and authentication tried as documented; SQL Server service/instance enumeration; isolated DPAPI recheck; no code or database changes.
- Blocked: current database name/existence and deployed object version cannot be confirmed without a successful authenticated connection. Full SQL Server regression, T9/T12/T13, and dual-session concurrency acceptance have not run.
- Manual action needed if the same documented configuration still fails: run the documented read-only connection from the user's normal interactive Windows session, or provide the approved test-only SQL Server endpoint/connection method and confirm the database name begins with `Codex_Persistence_`. Do not provide credentials in chat; use a local protected environment variable/secret store. For DPAPI, rerun under the Windows account that owns the vault/test profile. Once connection is restored, first query `DB_NAME()` and object/procedure definitions read-only, compare against the current repository SQL, and only then run the approved test suite.
- No code was changed in this follow-up. No database was created/deleted; no initialization, formal B3 password update, or formal order write was run. No commit, push, or merge.

## 7. 2026-11-26 test environment recovery follow-up

- The user confirmed a successful interactive PowerShell connection with `sqlcmd -S "lpc:." -E -C -d "Codex_Persistence_20261121_162302"`; therefore the target database name and interactive-session connection are confirmed by the user.
- This agent execution session retried the same read-only command plus an object inventory query and still failed before SQL execution: ODBC Driver 18 reports `Encryption not supported on the client` and `SSL Provider: no credentials available in the security package`. This differs by execution context; no security setting was weakened and no database query reached the server.
- Historical record says the isolated test database had member5 SQL commit `266ae3a` deployed. Current repository includes member5 commit `43c466a`; current database object version has not been confirmed. Do not run the full regression until the interactive-session preflight below confirms the latest procedure signatures/behavior. No SQL initialization or DDL is needed for this check.
- Status: historical target name confirmed by user; current database object version blocked by this execution-session TLS credential failure; real SQL Server regression not run; DPAPI recheck remains 2 failures at `_dpapi` in this execution context.
- Next: user may execute the safe preflight and regression command below in the same normal PowerShell session that successfully ran `sqlcmd`. It first enforces the `Codex_Persistence_` target, requires key M5 objects and signatures, and prints a read-only object inventory. It stops on failed preflight; otherwise it runs pytest against only the named isolated database. It does not create/drop a database or deploy SQL.

```powershell
$db = 'Codex_Persistence_20261121_162302'
$sql = @"
SET NOCOUNT ON;
IF DB_NAME() <> N'$db' OR DB_NAME() NOT LIKE N'Codex_Persistence[_]%'
    THROW 53000, N'Unexpected database; stop.', 1;
IF OBJECT_ID(N'dbo.rectification', N'U') IS NULL
 OR OBJECT_ID(N'dbo.subsidy_application', N'U') IS NULL
 OR OBJECT_ID(N'dbo.subsidy_audit_log', N'U') IS NULL
 OR OBJECT_ID(N'dbo.usp_M5_SubmitRectification', N'P') IS NULL
 OR OBJECT_ID(N'dbo.usp_M5_ReviewRectification', N'P') IS NULL
 OR OBJECT_ID(N'dbo.usp_M5_AssignAuditor', N'P') IS NULL
 OR OBJECT_ID(N'dbo.usp_M5_AuditAdvance', N'P') IS NULL
    THROW 53001, N'Required M5 objects missing; stop.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.parameters WHERE object_id=OBJECT_ID(N'dbo.usp_M5_SubmitRectification') AND name=N'@rectify_status')
 OR NOT EXISTS (SELECT 1 FROM sys.parameters WHERE object_id=OBJECT_ID(N'dbo.usp_M5_AssignAuditor') AND name=N'@assigned_to')
    THROW 53002, N'Expected procedure signatures missing; stop.', 1;
SELECT DB_NAME() AS database_name, d.state_desc
FROM sys.databases AS d WHERE d.name=DB_NAME();
SELECT s.name AS schema_name, o.name AS object_name, o.type_desc, o.modify_date,
       CONVERT(varchar(64), HASHBYTES('SHA2_256', CONVERT(varbinary(max), m.definition)), 2) AS definition_sha256
FROM sys.objects AS o
JOIN sys.schemas AS s ON s.schema_id=o.schema_id
LEFT JOIN sys.sql_modules AS m ON m.object_id=o.object_id
WHERE s.name=N'dbo' AND o.name IN
 (N'rectification',N'subsidy_application',N'subsidy_audit_log',N'sys_user',
  N'usp_M5_SubmitRectification',N'usp_M5_ReviewRectification',
  N'usp_M5_AssignAuditor',N'usp_M5_AuditAdvance')
ORDER BY o.type_desc,o.name;
"@
sqlcmd -S 'lpc:.' -E -C -d $db -b -Q $sql
if ($LASTEXITCODE -ne 0) { throw 'Read-only SQL preflight failed; regression was not started.' }

$env:ELDERCARE_TEST_DATABASE_URL = python -B -X utf8 -c "from sqlalchemy.engine import URL; print(URL.create('mssql+pyodbc', database='$db', query={'odbc_connect': 'DRIVER={ODBC Driver 18 for SQL Server};SERVER=lpc:.;DATABASE=$db;Trusted_Connection=yes;Encrypt=no;TrustServerCertificate=yes'}).render_as_string(hide_password=False))"
if ($LASTEXITCODE -ne 0 -or -not $env:ELDERCARE_TEST_DATABASE_URL) { throw 'Could not prepare test-only URL; regression was not started.' }
$temp = Join-Path $env:TEMP ('eldercare-sql-regression-' + [guid]::NewGuid().ToString('N'))
python -B -X utf8 -m pytest persistence_python -q --tb=short -p no:cacheprovider --basetemp $temp
$testExit = $LASTEXITCODE
Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item Env:\ELDERCARE_TEST_DATABASE_URL -ErrorAction SilentlyContinue
if ($testExit -ne 0) { throw "pytest failed with exit code $testExit" }
```

- Object inventory hashes and `modify_date` must be returned so they can be compared with current repository definitions; presence/signature checks alone do not prove an exact source match. If the preflight reports an old version or missing object, stop and report it rather than deploying SQL automatically.
- The previous two DPAPI tests were separately rerun with an external unique temp directory: **2 failed, 29 deselected** at `_dpapi`; no code change. Rerun those tests in the normal Windows user session separately after database regression, using an external basetemp.

## 8. 2026-11-26 interactive preflight result

- User ran the read-only preflight in a normal PowerShell session against `Codex_Persistence_20261121_162302`; the command connected successfully but stopped at `THROW 53001` (`Required M5 objects missing`). The guard combines three table checks and four procedure checks, so current evidence does not identify which object(s) are absent. The database-name/state query and object inventory were below the guard and did not run.
- No writes or DDL were performed. Do not run pytest or deploy initialization scripts yet. Next step is a read-only inventory of matching tables, views, and procedures in all schemas, plus the database name; use its output to identify whether the historical database is partial/stale or the expected object names/schema differ.

## 9. 2026-11-26 inventory analysis

- User-provided read-only inventory confirms database `Codex_Persistence_20261121_162302` is `ONLINE` and objects are under `dbo`. The required tables `rectification`, `subsidy_application`, `subsidy_audit_log`, `sys_user` exist.
- `dbo.usp_M5_SubmitRectification`, `dbo.usp_M5_ReviewRectification`, and `dbo.usp_M5_AssignAuditor` exist, each with `modify_date` 2026-11-22 14:45:59. `dbo.usp_M5_AuditAdvance` is absent. The inventory included all dbo objects matching `%M5%`; no such procedure row was returned.
- Current repository commit `43c466a` is dated 2026-11-23 and changed Submit/Review lock-then-UPDLOCK status validation and AssignAuditor account-status validation (52176); it also changed T12 to FAIL when AuditAdvance is absent. The current `member5/06_member5_procedures.sql` defines `usp_M5_AuditAdvance`, while this database has no such procedure. The objects' 2026-11-22 modify dates predate the latest procedure changes. Therefore this historical test database is stale for the current Python integration suite and must be updated before full regression.
- This conclusion is based on object existence and modify dates; the supplied inventory did not include `definition_sha256`, so exact module-by-module equality was not established. The missing AuditAdvance is conclusive regardless.
- No update/deployment was performed. Do not run pytest yet. Proposed next step: review a test-only deployment plan for the current `member5/06_member5_procedures.sql`, capture pre-deployment object definitions/backups or rely on source-controlled recreation procedure as appropriate, then deploy only after explicit authorization. Do not rerun schema/data initialization scripts and do not touch formal Data. After deployment, rerun read-only object/signature/hash preflight, then real full regression and dual-session tests.

## 10. 2026-11-26 review of member5 procedure deployment scope

- Reviewed all 651 lines of `member5/06_member5_procedures.sql`. The file contains no `USE` statement, database create/drop, table create/drop, truncate, top-level data insert/update/delete, or external command/bulk operation. It defines M5 triggers and procedures in the current database context. DML statements found are inside procedure/trigger bodies and execute only when those objects are later invoked.
- Deployment DDL drops and recreates `dbo.TR_M5_Item_Guard` and `dbo.TR_M5_Rect_SyncFlag`, and creates/alters the nine M5 stored procedures including `usp_M5_AuditAdvance`. Trigger drop/recreate creates a risk of partial deployment if run without a transaction. Recommended wrapper begins one outer transaction before including the SQL file and uses `sqlcmd -b`; an error exits the connection and leaves uncommitted DDL to roll back. Backup plus RESTORE VERIFYONLY must succeed first.
- For the proposed command, connection explicitly selects `Codex_Persistence_20261121_162302`, asserts `DB_NAME()` and the `Codex_Persistence_` prefix before backup/deployment, includes the source SQL file by absolute path, and verifies the required M5 objects after commit. No command is run against or configured for formal Data.
- Only the source file was statically reviewed; no deployment, backup, or database write was performed by this agent. The PowerShell deployment command was provided for the user to execute. Await user-reported backup, deployment, and post-deployment verification output before preparing/running pytest.

## 11. 2026-11-26 deployment result from user PowerShell

- User-provided output shows the post-deployment verification completed against `Codex_Persistence_20261121_162302`; all 9 expected M5 stored procedures and both M5 triggers are present. `usp_M5_AuditAdvance` now exists. `usp_M5_AssignAuditor.@assigned_to` and `usp_M5_SubmitRectification.@rectify_status` are output parameters; `usp_M5_AuditAdvance` has the expected eight inputs.
- Object `modify_date` values are 2026-11-26 22:05:43. The deployment wrapper's guards require the exact prefixed test database and all expected procedure/trigger objects before commit. Since the supplied transcript reached the post-deployment query, its prior backup, RESTORE VERIFYONLY, and deployment gates returned success; the pasted excerpt does not show the backup filename or intermediate output. Ask for the backup path if retention evidence is required.
- `persistence_python/models/__init__.py::prepare_models` only inspects existing table names and maps models; it does not call create_all or modify schema. Test fixtures do write/commit uniquely marked rows in the explicitly selected test database and clean their own rows. Full regression is now ready in the user's normal PowerShell session.
- Agent execution context still cannot negotiate SQL Server TLS credentials. No pytest was run from this agent. Next action: user runs the isolated-database pytest command in normal PowerShell and returns the full summary; this is not yet a test pass. DPAPI tests are included in that suite and should execute under the same Windows user context that can use DPAPI.

## 12. 2026-11-26 real SQL Server regression result

- User ran the full suite against the confirmed isolated database after deploying member5 procedures. A second run reproduced the same result: **210 passed, 3 failed, 77.93 seconds**. This is a completed run, not an active pytest process.
- Failures: `test_real_organization_three_states_without_reserved_orders` failed when dispatching the restored order with SQL error 51111 (caregiver has no valid qualification covering the appointment date); `test_real_isolated_20_order_batch_and_repeat_rejection` failed the Python preflight for the same qualification condition; `test_real_batch_failure_rolls_back_entire_batch` failed before its intended fifth-call injected error because the same qualification preflight aborted first. Thus the rollback test's expected injected failure was not exercised in this run.
- The three failures share an apparent test-data/qualification coverage prerequisite, but the log alone does not establish whether the fixture row values, SQL Server date conversion, test schema data, or object mismatch caused it. They are not evidence of a member5 procedure defect. No source code or test data was changed in response.
- Remaining: diagnose qualification rows/appointment dates inside an isolated test transaction before deciding on a fixture change; rerun affected tests and full suite after a confirmed correction. Current real DB result remains 3 failures, so the suite is not accepted as passing. User used normal PowerShell; test environment was the named isolated database. No formal Data writes were performed.

## 13. 2026-11-26 qualification fixture root cause and minimal fix

- The diagnostic fixture reported start `2026-11-29 22:19:41`, appointment `2026-11-29 23:19:41`, and certificate valid only through `2026-11-29`. The failing restored-order test schedules one hour after the fixture appointment, crossing midnight to 2026-11-30. The 20-order batch schedules every 10 minutes from 23:19, so later orders also cross into 2026-11-30. Both member2 dispatch validation and Python batch preflight correctly require the certificate to cover each appointment date. The batch rollback test therefore failed before reaching its injected fifth-call error.
- Minimal test-only fix in `persistence_python/conftest.py`: extend the synthetic certificate's `valid_to` through the date after `start`, covering the known cross-midnight scenarios. Production SQL, eligibility rules, and assertions are unchanged.
- The supplied inline diagnostic printed `qualifies=0` for an appointment and certificate with the same date; that status comparison included a Chinese SQL literal passed through the PowerShell-to-Python pipeline. Treat that computed flag as encoding-sensitive and not authoritative. The reported IDs, dates, and stored status are the useful evidence; regression execution in the repository source will verify the fix.
- Local verification: `python -B -m py_compile persistence_python/conftest.py` passed; `git diff --check` passed. This agent environment still cannot authenticate to SQL Server, so neither the three real SQL Server tests nor the full suite has been rerun after the fixture change. They remain pending in the user's normal PowerShell session. Only mark resolved after all three pass; run full suite only after targeted pass.

## 14. 2026-11-26 post-fix SQL Server regression passed

- User ran the three previously failing real-database tests first against `Codex_Persistence_20261121_162302`: **3 passed in 10.11 seconds**.
- User then ran the full `persistence_python` suite against the same isolated SQL Server database: **213 passed in 33.19 seconds**, with no failures or skips in the supplied output. This full suite includes the DPAPI tests; both therefore passed in the user's normal Windows PowerShell/user context on this run. This supersedes the prior 210 passed/3 failed result for the corrected fixture.
- Root cause and repair: test fixture certificate validity ended on the start date while realistic dispatch/batch appointments crossed midnight. `persistence_python/conftest.py` now extends only the synthetic certificate through the next date. Business SQL rules and assertions were unchanged.
- Current confirmed result: SQL Server integration suite passed; no formal Data database was targeted. Remaining original acceptance item: member5 standalone SQL T9/T12/T13 script has not been reported as executed in this round, so it remains unverified. No commit, push, or merge was performed.

## 15. 2026-11-26 member5 standalone SQL acceptance review

- Reviewed `member5/07_member5_tests.sql` in source at HEAD `ac99bae`. It has no `USE`, `COMMIT`, database create/drop, or SQLCMD include directive. All business-table `INSERT`/`UPDATE` statements are inside test transactions and the T1–T13 transaction paths explicitly roll back; the script writes only session-local `#res` for its report outside those test transactions. Its header states test transactions are rolled back. The file itself does not contain a database-name guard, so execution must use the guarded PowerShell/sqlcmd wrapper below with the exact isolated database.
- T9 checks institution-level restriction removal using create inspection → create rectification → submit → review pass, asserts `待复查/Y` before review and checks the caregiver-blocked view afterward. It rolls back both success and error paths. It is SKIP if required tables/accounts/orders are absent or no currently unrestricted organization is available; a SKIP is not a pass.
- T12 first checks `usp_M5_AuditAdvance` exists; its absence is FAIL. It tests a preassigned application advancing from `待社区初审` to `街道复审中`, clearing `current_auditor_id` while retaining the actual auditor in the audit log, then separately checks stale expected status is rejected with error 52175. Both attempts roll back. It is SKIP if the application or community account prerequisite is absent.
- T13 tests create → submit → review fail → resubmit; it requires final `待复查` with restriction still `Y`, and rolls back. It is SKIP if the required user/order/organization rows are absent.
- The script reports per-case PASS/FAIL/SKIP and throws 52310 if any case is FAIL. Its structural checks require six member5 tables, expected views/triggers, and nine procedures (including `usp_M5_AuditAdvance`). The user previously reported deployment of the current procedure script to the isolated DB, but T9/T12/T13 have not yet been run/reported in this acceptance round. Status: static scope review complete; live standalone SQL acceptance pending.
- **User then executed the guarded command** against `Codex_Persistence_20261121_162302`; guard reported ONLINE and `sqlcmd` exited 0. The log showed all six member5 business tables at **0 rows** and summary **PASS 3 / FAIL 0 / SKIP 10**. T9 SKIP: no currently unrestricted organization; T12 SKIP: no `待社区初审` application/community account; T13 SKIP: no usable rows in `sys_user` / `service_order` / `service_org`. Thus T9/T12/T13 were invoked but their business assertions did not execute; these are not accepted as passes. The script's final `PASS 部署验收` only indicates there were no FAIL rows, despite 10 SKIPs. The pasted console output renders Chinese text as mojibake, so preserve the original log for readable/encoding-correct confirmation. No seed script has been run based on this result.
- The same pasted transcript includes the full Python/SQL Server regression result **213 passed in 33.19s**. This remains the user-run full suite result; it does not change the standalone SQL SKIPs.
- Existing real dual-session Python coverage was inspected. `test_concurrency.py::test_two_connections_lock_isolation_and_final_value` uses two independent sessions, a writer transaction and a reader using `READCOMMITTEDLOCK`; an observer polls `sys.dm_exec_requests` to verify actual blocking, then both commit/rollback cases assert the observed and final value. `test_audit_tasks.py` additionally checks concurrent same-node audit under commit/rollback, assignment-vs-ownership serialization, last-successful concurrent assignment, and dispatch vs organization restriction using independent sessions and a blocking-session observer. The user-reported full SQL Server suite passed **213 tests, no skips**, which includes these Python concurrency cases. T12's “concurrent conflict” case itself is a stale-status rejection check in one session, not a two-session race; the Python concurrency tests provide the actual two-session evidence.
- No code or SQL source was changed for this review. No database was connected or modified from this execution context. No formal `Data` database, initialization script, commit, push, or merge was used.
- Next: inspect `member5/03_member5_test_data.sql` for write scope, rerun/idempotency behavior, and required member1/2/3 prerequisite data before deciding whether to seed the isolated database. Do not repeat initialization scripts blindly. Only after safe, isolated test data is available should T9/T12/T13 be rerun; each must say PASS, with remaining SKIPs explained. Do not infer acceptance from sqlcmd exit 0 alone.

```powershell
$ErrorActionPreference = 'Stop'
$db = 'Codex_Persistence_20261121_162302'
$sqlFile = Join-Path (Get-Location).Path 'member5\07_member5_tests.sql'
if (-not (Test-Path -LiteralPath $sqlFile -PathType Leaf)) {
    throw "SQL test script not found: $sqlFile"
}

# Put the retained result log in the task work directory, outside the repository.
$workDir = Join-Path $env:USERPROFILE 'Documents\Codex\work\member5-t9-t12-t13-20261126'
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
$logFile = Join-Path $workDir ('07_member5_tests_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')

# Guard the exact isolated database and verify that it is online before running any test SQL.
$guard = @"
SET NOCOUNT ON;
IF DB_NAME() <> N'$db' OR DB_NAME() NOT LIKE N'Codex_Persistence[_]%'
    THROW 53000, N'Unexpected database; stop.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = DB_NAME() AND state_desc = N'ONLINE')
    THROW 53001, N'Test database is not ONLINE; stop.', 1;
SELECT DB_NAME() AS database_name, state_desc
FROM sys.databases WHERE name = DB_NAME();
"@
sqlcmd -S 'lpc:.' -E -C -d $db -b -Q $guard
$guardExit = $LASTEXITCODE
if ($guardExit -ne 0) {
    throw "Database guard failed (sqlcmd exit $guardExit); test script was not started."
}

# Run only the standalone rollback-based acceptance script; retain its full output.
sqlcmd -S 'lpc:.' -E -C -d $db -b -f 65001 -i $sqlFile -o $logFile
$testExit = $LASTEXITCODE
Write-Host "sqlcmd exit code: $testExit"
Write-Host "Full result log: $logFile"
Get-Content -LiteralPath $logFile -Encoding UTF8
if ($testExit -ne 0) {
    Write-Warning 'Standalone acceptance reported an error. Keep the log and do not treat the run as passed.'
}
```

## 16. 2026-11-26 standalone SQL run result and follow-up

- User executed the guarded script against `Codex_Persistence_20261121_162302`; guard returned ONLINE and sqlcmd exit code was 0. All six M5 business tables reported 0 rows. Business summary: **PASS 3 / FAIL 0 / SKIP 10**. T9, T12, and T13 were each **SKIP**, so these cases are not accepted as passed. The script prints a final deployment PASS when there are no FAIL rows; that does not convert SKIPs into passes.
- Transcript reasons: T9 had no currently unrestricted organization; T12 had no `待社区初审` application/community account; T13 had no usable `sys_user`, `service_order`, and/or `service_org` rows. The three business PASS cases were T4, T6, and T7. Preserve the per-case status and distinguish these from the structural PASS.
- Pasted transcript also reports the full Python/SQL Server suite at **213 passed in 33.19s**. This does not change the M5 standalone skips.
- The user-provided output showed garbled Chinese in the saved log, although ASCII counts/statuses were readable. Retained log path: `C:\Users\65770\Documents\Codex\work\member5-t9-t12-t13-20261126\07_member5_tests_20261126_222910.log`.
- Read-only review of `member5/03_member5_test_data.sql` shows it commits test rows on success and rolls back only on error. It uses marker checks but can create marked test orders as well as M5 policy/application/audit/inspection/rectification rows, and requires parent data and member 4 role accounts. It was **not executed**; do not run blindly. Inspect existing prerequisites and intended data effects before preparing the isolated test database.
- Summary record: [2026-11-26_member2_acceptance_record.md](2026-11-26_member2_acceptance_record.md).

## 17. 2026-11-26 M5 seed-data preparation plan (pending)

- Static review of `member5/03_member5_test_data.sql`: prerequisites are existing M5 tables/procedures, parent `service_item`, `elder_profile`, `service_order`, `service_org`, `sys_user`, at least one active subsidizable item, nonempty elders/orgs, and Community/Street/Civil reviewer accounts (role codes or documented fallback usernames). It may add up to 23 marked completed orders, then M5 policy/application/item/audit/inspection/rectification data for 20 cases. It commits on success and rolls back on error; it is not an ephemeral test. It creates neither `caregiver` rows nor accounts.
- Repeat risk: marker checks protect many same-month rows, but `@cycle` changes monthly; a later execution can create another set of applications/audit rows, while globally unique order details may be skipped. Treat as one-time preparation after marker/count preflight, not as blindly repeatable.
- T9 additionally requires at least one caregiver in an organization that remains free of institution-level restrictions after the seed sample's active rectifications. The M5 seed script does not create that prerequisite. T12 needs a Community Admin and a `待社区初审` application; T13 needs populated users/orders/organizations.
- Plan: first run read-only preflight on only `Codex_Persistence_20261121_162302`; verify required parents/roles, M5 marker counts, and T9 caregiver-organization candidates. If prerequisites are missing, stop and request the relevant member 1/3/4 test dataset instead of running unrelated initialization. If all prerequisites are met and the persistent seed plan is confirmed, run `03_member5_test_data.sql` once, verify its marker counts, then run `07_member5_tests.sql` and the focused two-session Python concurrency tests. Require T9/T12/T13 each PASS; any SKIP remains outstanding.
- The seed script commits permanent test rows, so do not execute it until the read-only preflight is reviewed and the user confirms this exact persistent test-data preparation plan.
- Current blocker: this agent execution environment's read-only `sqlcmd -S lpc:. -E -C -d Codex_Persistence_20261121_162302` attempt failed before connecting with ODBC Driver 18 TLS credential negotiation errors (`Encryption not supported on the client` / `no credentials available in the security package`). No query reached SQL Server; no data script or test was executed. A normal PowerShell-session preflight result is needed before any persistent seed write. The full 213-test result is prior user-reported evidence and is not the focused rerun requested here.
- No B1/B2 initialization, formal `Data` access, commit, push, or merge was performed.

## 18. 2026-11-26 isolated database read-only preflight result

- User ran the guarded count query in normal PowerShell. It confirmed the exact isolated DB is ONLINE. Counts: 20 service items (15 active/subsidizable), 20 elders, 5 service organizations, 0 service orders, 0 subsidizable orders, 0 caregivers, 0 work records, 5 users (one each Community Admin/Street Supervisor/Civil Supervisor), and all six M5 business tables at 0 rows.
- This explains the standalone skips precisely: T9 has no caregivers; T12 has no applications (Community Admin exists); T13 has no service orders (users and organizations exist). The member5 03 script's required parents, eligible service items, and reviewer roles are present; with no eligible orders it may create 23 marked test orders and commit M5 test data. It does not seed caregivers.
- Read-only review of member3 `05_M3_TestData-v2.sql` found a separate BASE stage that can seed 22 marked caregivers, 24 certificates, and 22 schedules, but it defaults to `@AllowWrite=0` and requires exact actual organization/service-item business keys and trusted FKs. No M3 or M5 data script was executed. Actual service organization/business-key selection and external FK confirmation remain pending.
- M5 seed creates active organization-level restriction samples at sorted service-org ordinals 2 and 3 (the active cases are data indices 3 and 7). To retain a T9 candidate, all M3 test caregivers should be assigned to a confirmed eligible org outside those ordinals, after confirming the actual org ordering/keys. Run persistent seed stages only after reviewing that preflight and confirming the plan; then rerun 07 and the focused real two-session tests.
- No database write occurred during this read-only check. The earlier agent-side TLS credential failure remains a limitation of that execution context; the successful user-side preflight provides counts only, not approval or execution of seed scripts.
- Updated detailed status: [待办事项与联调材料清单](待办事项与联调材料清单.md), [acceptance record](2026-11-26_member2_acceptance_record.md).

## 19. 2026-11-26 Windows identity comparison and connection recovery

- Historical 2026-11-22 development record identifies the same isolated DB `Codex_Persistence_20261121_162302`, ODBC Driver 18, Windows integrated authentication, and a successful `sqlcmd -C` connection followed by a **160 passed / 0 failed / 0 skipped** database regression. It also records the Python URL using `Trusted_Connection=yes`. That record does not capture `whoami`, Windows SID, or the exact terminal process identity, so historical identity cannot be proven from the artifact alone.
- Current default execution shell is Windows PowerShell 5.1, SessionId 1, Python `C:\Users\65770\anaconda3\python.exe`, and the same ODBC Driver 18 installation, but its actual principal is `无欲\CodexSandboxOffline`, SID `S-1-5-21-64405934-2448206393-318614616-1003`. `USERPROFILE` still points at `C:\Users\65770`; that path did not mean the process had the interactive user's token or DPAPI keys. This default shell failed SQL integrated authentication with `Encryption not supported on the client` / `no credentials available in the security package`, and the two user-DPAPI tests failed under that sandbox context.
- Used the platform's controlled host-context authorization (`require_escalated`) without changing Windows/SQL security settings. The authorized process ran as `无欲\65770`, SID `S-1-5-21-64405934-2448206393-318614616-1001`, with the same PowerShell version, SessionId, ODBC and Python paths. The guarded read-only `sqlcmd -S lpc:. -E -C -d Codex_Persistence_20261121_162302` returned the exact isolated database. An ODBC read-only `SELECT DB_NAME()` also succeeded with `Encrypt=yes`; local certificate trust was scoped to this local self-signed server connection. No global TLS settings were changed and encryption was not disabled.
- Retested the two DPAPI cases under `無欲\65770` with a unique task temp directory: `test_dpapi_roundtrip_no_plaintext_and_no_overwrite` and `test_tampered_vault_and_wrong_slots_fail_closed` => **2 passed in 0.15s**. This confirms the observed DPAPI failure was the sandbox identity/SID difference, not a code change. No vault or test secrets were printed.
- The SQL Server connection and DPAPI test are now available through the authorized host-context execution path; no manual PowerShell output copy is needed for further tool commands in this session. Default sandbox SQL/DPAPI access remains unavailable. This is a per-command authorization flow, not a global security relaxation.
- Read-only business-key preflight in the recovered context confirmed five organizations, with org ordinal 1 `阳光社区养老服务中心 / 阳光社区服务街道1号 / 阳光社区` in normal status. The M3 FKs `FK_M3_caregiver_org_id` and `FK_M3_caregiver_certificate_service_id` are enabled and trusted. The existing service item `M2测试-上门保洁 / 家政` is active and subsidizable. It matches the M3 BASE test script's organization/community defaults and avoids the org ordinals 2 and 3 that M5 seed data will institution-restrict.
- The persistent M3 BASE and M5 03 test-data scripts remain **unexecuted pending confirmation**. The exact proposed isolated-data sequence is: M3 BASE using the verified organization and service-item business keys; M5 `03_member5_test_data.sql` once (expected to create 23 marked orders because current eligible order count is 0); M5 `07_member5_tests.sql`; then focused real two-session pytest cases. Require T9/T12/T13 each PASS and report all SKIPs. No business code, source SQL, SQL Server configuration, or formal `Data` was changed in this recovery.

## 20. 2026-11-26 isolated seed and M5 acceptance execution

- Target was guarded before SQL execution: `Codex_Persistence_20261121_162302`; the test database was ONLINE. No formal `Data` database was selected or written. Execution identity: `无欲\65770` (SID ending `-1001`) via the platform-controlled host authorization path; Windows integrated authentication, ODBC Driver 18, encryption enabled. No credentials were printed or stored.
- Recovery point: SQL Server `COPY_ONLY` full backup with `CHECKSUM` and `COMPRESSION` completed for this isolated database before seeding; `RESTORE VERIFYONLY WITH CHECKSUM` reported the backup set valid. File: `C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\Backup\Codex_Persistence_20261121_162302_before_M3_M5_seed_20261126_230450.bak`.
- M3 BASE used a temporary copy of `member3/sql/05_M3_TestData-v2.sql` under `C:\Users\65770\Documents\Codex\work\m2-env-recovery-20261126`; original SQL was unchanged. Exact verified organization/service keys were used. Post-run read-only counts: 22 caregivers, 24 certificates, 22 schedules with the `M3T2030` marker.
- M5 `03_member5_test_data.sql` first stopped at `QUOTED_IDENTIFIER` because the sqlcmd session omitted the project-required `-I` option. The script's transaction rolled back on error. It was retried once, unchanged, with `sqlcmd -I`; output reported completion. Post-run counts: subsidy_policy 20, subsidy_application 20, subsidy_application_item 20, subsidy_audit_log 26 (20 seeded initial-node records plus 6 additional-stage audit records), quality_inspection 20, rectification 20. No second seed rerun was performed.
- `member5/07_member5_tests.sql` ran against the guarded isolated DB with `sqlcmd -I -C -E -b -f 65001`. Result: **PASS 13 / FAIL 0 / SKIP 0**. Required checks all passed: **T9** institution restriction cleared after passed recheck; **T12** node transition cleared current assignee while preserving auditor in history and rejected stale status; **T13** failed recheck allowed resubmission and kept restriction active. Test script is transaction/rollback based.
- Real SQL Server dual-session tests ran with encrypted ODBC and Windows integrated authentication: `test_two_connections_lock_isolation_and_final_value` (commit and rollback parameter cases), `test_real_concurrent_single_node_audit_component` (both commit-first cases), `test_real_assignment_and_ownership_check_serialize`, `test_real_concurrent_assignments_last_success_wins`, and `test_real_dispatch_serializes_with_organization_restriction`: **7 passed in 10.55s**. Two startup attempts did not reach SQL tests (PowerShell inline quoting, then SQLAlchemy URL omitted its database component); the corrected invocation passed all cases.
- The M5 seed and M3 BASE rows persist in the isolated test DB by design and are covered by the verified backup. T9/T12/T13 business tests roll back. No full 213-test suite was rerun during this seed/acceptance execution; the earlier user-run **213 passed** is retained as historical evidence only.
- Source version at start: branch `feature/member2-b3-credentials`, HEAD `ac99baee4bb1ed5daf67e825bdffc02671bb20da`. No source SQL/Python was changed in this execution. Existing unrelated working-tree modifications remain; review/stage them separately before any commit. No commit, push, or main merge occurred.
- Logs and temporary runner: `C:\Users\65770\Documents\Codex\work\m2-env-recovery-20261126` (outside repository). M5 retry log: `03_member5_test_data_retry.log`; SQL acceptance log: `07_member5_tests.log`.

### Status after this run

- Completed and verified: guarded isolated DB backup validation; M3 BASE fixture preparation; M5 fixture initialization; T9/T12/T13; seven real SQL Server concurrency cases; connection and DPAPI environment recovery documentation.
- Pending: decide whether to run the full Python suite again against the now-seeded isolated database; review and stage the intended source/document changes for GitHub. Rectification review-history schema adequacy remains a cross-member confirmation item; no table schema was changed.
- Blocked: none for the requested M5 acceptance and two-session checks. Formal Data remains outside scope and untouched.

Next: review `git diff` and `git status`, stage only the files intended for this delivery, then commit/push on the current feature branch if desired. Keep the history-traceability question as an explicit cross-member follow-up.
