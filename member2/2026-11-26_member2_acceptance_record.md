# Member 2 Integration Acceptance Record - 2026-11-26

## Executive summary

The user ran the guarded member 5 standalone SQL acceptance script against the isolated SQL Server database `Codex_Persistence_20261121_162302`. The database guard passed and `sqlcmd` exited with code 0. However, all six member 5 business tables contained zero rows. The script summary was **PASS 3 / FAIL 0 / SKIP 10**. Target cases T9, T12, and T13 were all skipped, so they are **not accepted as passed**.

The pasted transcript also includes the Python/SQL Server suite result **213 passed in 33.19 seconds**. That suite result is separate from the standalone SQL cases and does not change their skipped status.

## Observed standalone SQL run

- Target database: `Codex_Persistence_20261121_162302`; guard output: `ONLINE`.
- Source: `member5/07_member5_tests.sql` at repository HEAD `ac99bae`.
- `sqlcmd` exit code: `0`.
- The six member 5 table row counts (`subsidy_policy`, `subsidy_application`, `subsidy_application_item`, `subsidy_audit_log`, `quality_inspection`, `rectification`) were each `0`.
- Script business summary: **PASS 3 / FAIL 0 / SKIP 10**. It prints `PASS deployment acceptance` if no test row is FAIL; that message does not mean skipped tests passed.
- T9: **SKIP**, no currently unrestricted organization available for the test.
- T12: **SKIP**, no `待社区初审` application or community account available.
- T13: **SKIP**, no usable rows in `sys_user`, `service_order`, and/or `service_org` according to the test precondition.
- Other cases were also skipped due to missing test data. The three PASS business cases were T4, T6, and T7; the structural acceptance line also passed.
- Retained log reported by the user: `C:\Users\65770\Documents\Codex\work\member5-t9-t12-t13-20261126\07_member5_tests_20261126_222910.log`.
- The pasted log text has garbled Chinese characters despite `-f 65001` and `Get-Content -Encoding UTF8`; the ASCII counts/statuses above were visible. Keep the original log if a later report needs raw evidence.

### Follow-up read-only preflight (user PowerShell)

- The database guard again confirmed `Codex_Persistence_20261121_162302` is ONLINE.
- Counts: `service_item=20`, active subsidizable items `=15`, `elder_profile=20`, `service_org=5`, `service_order=0`, subsidizable service orders `=0`, `caregiver=0`, currently unrestricted caregiver organizations `=0`, `sys_user=5`, Community Admin `=1`, Street Supervisor `=1`, Civil Supervisor `=1`, `work_record=0`. Each of the six M5 business tables remains at 0 rows.
- This resolves the SKIP causes: T9 has no caregiver rows; T12 has reviewer account but no applications; T13 has users and organizations but no service orders. The result refines the earlier generic reasons from the 07 log.
- The 03 M5 seed prerequisites are present: parent tables/rows, active subsidizable items, and all three reviewer roles. With zero eligible service orders it can attempt to add 23 marked completed orders, then create the M5 test set. It still cannot create caregivers, so it cannot by itself make T9 runnable.
- Static read-only review of `member3/sql/05_M3_TestData-v2.sql`: BASE is a distinct test-only write stage that creates 22 marked caregivers, 24 certificates, and 22 schedules; it defaults to `@AllowWrite=0`, requires exact existing organization and service-item business keys plus trusted FKs, and commits on success. It refuses a duplicate `M3T2030` caregiver batch. The actual test DB organization/service-item keys have not yet been queried. Because M5 03 creates active institution restrictions at org ordinals 2 and 3 (sorted by `org_id`), the M3 test caregiver organization must be a valid confirmed organization at another ordinal to leave a T9 candidate after M5 seeding.
- No seed script has been executed. The remaining read-only step is to inspect the five actual organization business keys/areas/statuses and service-item names/types, and verify required M3 external FKs. Then confirm a specific isolated test-data plan before either persistent seed script runs.

## Static review of T9, T12, and T13

- `07_member5_tests.sql` has no `USE`, `COMMIT`, database create/drop, or SQLCMD include directive. It does not contain its own target database guard. Its business table writes are inside explicit test transactions that roll back; the result table is session-local `#res`.
- T9 exercises institution-level restriction removal: create inspection, create rectification, submit (expected `待复查` with restriction `Y`), review pass, then check the blocked-caregiver view. Success and error paths roll back.
- T12 checks that `usp_M5_AuditAdvance` exists, tests node transition and clearing `current_auditor_id` while keeping the actual auditor in the log, and checks stale expected status rejection using error 52175. Its stale-status case is single-session validation, not a two-session race. Each transaction rolls back.
- T13 exercises submit, failed review, and resubmission; expected final state is `待复查` with restriction `Y`. The transaction rolls back.
- Static side-effect review is complete. The user's run confirms the script executed in the intended isolated database, but T9/T12/T13 business assertions were skipped by data prerequisites.

## Existing concurrency tests

- `persistence_python/test_concurrency.py::test_two_connections_lock_isolation_and_final_value` uses independent SQL sessions and an observer polling `sys.dm_exec_requests` to confirm actual blocking. It covers writer commit and rollback and checks both the reader's observed value and the final value.
- `persistence_python/test_audit_tasks.py` covers concurrent same-node audit with commit/rollback, assignment versus ownership-check serialization, concurrent assignment final ownership, and dispatch versus organization restriction. These tests observe actual SQL Server blocking.
- These Python concurrency tests are included in the user-reported 213-test full run. That is evidence for the Python concurrency coverage, not for standalone SQL T9/T12/T13.

## Test data script risk review

The likely next preparation candidate is `member5/03_member5_test_data.sql`, but it was **not executed**. Static inspection shows it starts a transaction and commits on success (`COMMIT` near line 343; rollback in `CATCH`), so it persists test rows. It uses marker-based existence checks and states that it is repeatable, but it may also create marked service orders when fewer than the target number are available. It requires existing parent data (`service_item`, `elder_profile`, `service_order`, `service_org`) and member 4 role accounts in `sys_user`. Review the complete effects and prerequisites against current isolated database contents before deciding whether to run it. Do not confuse it with the rollback-only `07_member5_tests.sql` acceptance script.

### Detailed write scope and repeat risk

- Before the transaction, the script requires the M5 policy table, parent tables `service_item`, `elder_profile`, `service_order`, `service_org`, `sys_user`, at least one active subsidizable service item, at least one elder and organization, and role accounts for `COMMUNITY_ADMIN`, `STREET_SUPERVISOR`, and `CIVIL_SUPERVISOR` (or fallback usernames).
- Inside a transaction it may create enough marked completed service orders to reach 23 subsidizable orders; it then prepares up to 20 M5 policies, applications, application items, audit logs, inspections, and rectifications. It commits all successful inserts. It does not create caregivers or user accounts, and it does not ensure a caregiver exists in an unrestricted organization, so this script alone cannot guarantee T9.
- Marker checks make a same-month rerun partly idempotent, not universally repeat-safe. The application cycle is derived from the current `YYYY-MM`; rerunning in a later month can create another set of applications and audit logs. Application-item insertion is guarded by globally unique order usage, so a later run may create applications without adding their details. Do not rerun blindly.
- The previous standalone run showed all six M5 tables at zero rows, but did not establish all parent counts or role availability. A read-only preflight is still required before any seed write.

### Execution plan and current blocker

1. Run a read-only preflight against only `Codex_Persistence_20261121_162302`: assert exact database name/prefix and ONLINE; count required parent tables, active subsidizable items, elders, organizations, orders, caregivers, work records, required role accounts, current community-review applications, and M5 marker rows; count caregivers in organizations not already institution-restricted.
2. Proceed with `03_member5_test_data.sql` only if its required parents and role accounts exist, there are no conflicting M5 marker rows, and at least one caregiver organization is expected to remain unrestricted after the script's two active institution-level sample rectifications. If these conditions fail, stop and identify the missing member 1/3/4 dataset; do not run unrelated initialization scripts.
3. Run the M5 data script once in the isolated database, retain its output, and verify per-table marker counts. It is an intentional persistent test-data load; it is not a rollback-only test.
4. Run `07_member5_tests.sql`; require T9, T12, and T13 individually PASS. A zero sqlcmd exit with SKIPs is not acceptance.
5. Rerun the focused real dual-session tests: `test_concurrency.py::test_two_connections_lock_isolation_and_final_value`, `test_audit_tasks.py::test_real_concurrent_single_node_audit_component` (both commit/rollback cases), `test_real_assignment_and_ownership_check_serialize`, `test_real_concurrent_assignments_last_success_wins`, and `test_real_dispatch_serializes_with_organization_restriction`.

The agent's current execution environment attempted only a read-only `sqlcmd` inventory and failed before connecting: ODBC Driver 18 reported `Encryption not supported on the client` and `SSL Provider: no credentials available in the security package`. No SQL query or data write reached SQL Server. Consequently, the seed script and follow-on T9/T12/T13/concurrency reruns remain pending in the user's normal PowerShell session. The previous user-run full suite of 213 passed remains valid historical evidence but does not satisfy this focused rerun.

## Next steps

1. In normal Windows PowerShell, inspect the isolated database's actual organization/service-item business keys and M3 external FKs; confirm a suitable organization at sorted ordinal 1, 4, or 5 (or another org not made restricted by the M5 seed distribution).
2. After explicit confirmation of the persistent data preparation, run the existing M3 BASE test-data stage with only confirmed business keys, then run `03_member5_test_data.sql` once. Retain outputs and verify counts.
3. Run `07_member5_tests.sql` and the focused dual-session tests.
4. Mark T9/T12/T13 accepted only if each reports PASS. Report all remaining SKIPs explicitly. `sqlcmd` exit code 0 alone is insufficient.

## Scope and provenance

- No formal `Data` database was connected to or written by the reported commands. The standalone acceptance command targeted only the named `Codex_Persistence_` database.
- No initialization or seed script was run in this review. No source SQL or Python code was changed in this review.
- No commit, push, or merge to `main` was performed.
- Detailed integration history and the guarded command are in [2026-11-26_member2_integration.md, section 15](2026-11-26_member2_integration.md#15-2026-11-26-member5-standalone-sql-acceptance-review).

## Execution-context diagnosis and recovery

- The 2026-11-22 development record confirms the same isolated SQL Server DB, ODBC Driver 18, Windows integrated authentication, successful `sqlcmd -C`, and 160 passed database regression. It does not record `whoami`, SID, or terminal token, so the historical process identity is unknown.
- Current default sandbox shell uses PowerShell 5.1, SessionId 1, ODBC Driver 18 and Python `C:\Users\65770\anaconda3\python.exe`, but the token is `无欲\CodexSandboxOffline` / SID ending `-1003`. It has the same `USERPROFILE` path as the interactive user but no corresponding SSPI credentials or user DPAPI master key. Its sqlcmd attempt fails before SQL execution with missing SChannel credentials.
- Through the platform's controlled host-context authorization, the same shell tools run as `无欲\65770` / SID ending `-1001`. Under this identity, guarded sqlcmd and encrypted ODBC (`Encrypt=yes`) both returned `Codex_Persistence_20261121_162302`; no global security setting was changed and transport encryption remained enabled. DPAPI tests `test_dpapi_roundtrip_no_plaintext_and_no_overwrite` and `test_tampered_vault_and_wrong_slots_fail_closed` passed: **2 passed in 0.15s**.
- Thus the difference is the Windows security principal/SID, not the visible profile directory, Python binary, ODBC driver, database name, or test code. The standard sandbox still cannot use SQL Server/DPAPI; use the authorized host-context execution path for future database commands and DPAPI checks. No manual output copy is needed when that authorization path is available.

## Verified isolated test-data candidate keys (read-only)

- Organization ordinal 1: `阳光社区养老服务中心 / 阳光社区服务街道1号 / 阳光社区`, status normal. M3 external FKs `FK_M3_caregiver_org_id` and `FK_M3_caregiver_certificate_service_id` are enabled/trusted.
- Service item business key `M2测试-上门保洁 / 家政` exists, active and subsidizable. It matches the M3 BASE script's expected community/organization defaults. Ordinal 1 remains outside the two org ordinals (2 and 3) that M5 03 will restrict, leaving a T9 candidate.
- The proposed persistent sequence is M3 BASE using those verified keys, M5 03 once, M5 07, then focused real dual-session tests. M3 BASE and M5 03 both commit test data; neither has been run. User confirmation of this concrete persistent fixture sequence is still pending.

## 2026-11-26 isolated M3/M5 preparation and focused acceptance (completed)

- Database: `Codex_Persistence_20261121_162302` only; guarded exact database name and prefix. No formal `Data` database was used.
- Backup before data preparation: SQL Server COPY_ONLY full backup with CHECKSUM/COMPRESSION; `RESTORE VERIFYONLY WITH CHECKSUM` succeeded. Backup file: `C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\Backup\Codex_Persistence_20261121_162302_before_M3_M5_seed_20261126_230450.bak`.
- M3 BASE, temporary script copy only: 22 caregivers, 24 certificates, 22 schedules. Original member3 SQL was not edited.
- M5 03 seed: first attempt failed before completion because sqlcmd omitted `-I` (QUOTED_IDENTIFIER). Transactional error handler rolled back. One retry with `-I` completed: policy 20, application 20, application item 20, audit log 26 (includes six additional audit-stage records), inspection 20, rectification 20. No duplicate rerun.
- M5 07 standalone SQL acceptance: **13 PASS / 0 FAIL / 0 SKIP**. T9 PASS, T12 PASS, T13 PASS. Other test cases also passed. The acceptance script ran in rollback transactions.
- Focused two-session SQL Server concurrency suite: **7 passed in 10.55s**, covering commit/rollback isolation, concurrent same-node review, assignment/ownership serialization, concurrent assignments, and dispatch against organization restriction. Encrypted ODBC and Windows integrated auth were used.
- This was a focused acceptance run, not a fresh full Python suite. Earlier user-run full suite of 213 passed remains historical and is not relabeled as this run.
- No business code or source SQL changed. No commit/push/merge was performed. Rectification review history remains a cross-member schema confirmation item.
- Logs are outside the repository under `C:\Users\65770\Documents\Codex\work\m2-env-recovery-20261126`.

## 2026-11-26 post-seed full Python regression (completed)

- Initial full run after persistent M3/M5 fixtures: 212 passed, 1 failed in 87.48s. The failure was `test_real_todo_filter_and_locked_identity_refresh`: five valid unassigned community-stage applications from M5 seed data were returned alongside the test's two rows. The test incorrectly assumed an otherwise empty audit queue; the DAO behavior was correct.
- Fixed only the test in `persistence_python/test_audit_tasks.py`: validate fixture rows by presence/absence, retain wrong-stage and wrong-owner exclusions, and derive the page number from the current result ordering. No business rule or SQL was changed.
- Focused test: 1 passed in 8.61s.
- Full regression rerun against `Codex_Persistence_20261121_162302`, encrypted ODBC / Windows integrated auth: **213 passed in 81.81s**. Log: `C:\Users\65770\Documents\Codex\work\m2-env-recovery-20261126\pytest-full-final-ab65499cc43e4282b518d9747077ce82\pytest-full.log`.
- Together with the just-completed M5 SQL acceptance (13 PASS / 0 FAIL / 0 SKIP, T9/T12/T13 PASS) and focused two-session suite (7 passed in 10.55s), the requested testing is complete. No formal `Data` DB access/write occurred.
- Follow-up edits are in a separate feature-branch worktree based on `c74820410a02ff3ae26f75ae6fa687a39cedb64c`; no commit/push/merge was done in this follow-up. Rectification history-schema confirmation remains open.
