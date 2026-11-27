# B3机构绑定补充联调归档索引

成员4原始提交：`0dbec64b5f5781c730e3dfacc7c97e4f11d7df8b`。成员2联调执行基线：`101b3d635ce74015b9199b09bf48242da6738ee5`。本归档仅记录阶段性复验，**不代表整体最终验收通过**。

动态选择的实际结果为 `org_mgr_1→机构1（阳光社区养老服务中心）`、`org_mgr_2→机构6（M3T2030联调机构01）`，`comm_admin` 同步绑定机构1。机构ID来自真实数据和独立副本原始初始化脚本输出，不是脚本硬编码。原库按副本结果进行的测试绑定迁移，与原始脚本在副本成功执行的证据分开记录。

| 验证项目 | 归档结论 |
|---|---|
| B3专项 | 21/21通过 |
| 原库完整14脚本 | 24通过、7失败，THROW 57002 |
| 两库verify_b3 | 各28账号登录、Session、注销通过，退出码均0 |
| 机构权限及越权检查 | 27/27检查分组通过；不是pytest计数 |
| 数据回滚 | 原库21张业务表逐行哈希一致；仅三个测试账号保留新机构绑定 |
| M5整改提交闭环 | 待成员5确认；本轮仅验证回滚事务中的真实责任方提交权限和状态转换 |
| M5多轮复查结构化历史契约 | 待成员5确认；未改表或过程 |

完整SQL脚本的7项失败保留如下，不能将B3专项通过写成完整脚本通过：

| M4缺项 | 实际 | 预期 |
|---|---:|---:|
| M4TEST设备 | 0 | 20 |
| M4TEST体征 | 0 | 20 |
| M4事件 | 0 | 20 |
| 已闭环事件 | 0 | 8 |
| 处置中事件 | 0 | 4 |
| 待响应事件 | 0 | 6 |
| 已误报事件 | 0 | 2 |

以下为本目录完整证据文件清单（另含本索引、SHA256SUMS.txt和保留原始字节的.gitattributes）：

| 文件 | 用途 |
|---|---|
| supplement-summary.json | 本轮结果、动态绑定和剩余待办的结构化摘要 |
| source-versions.json | 成员4原始提交与两个原始SQL的SHA256 |
| member4-full.diff | 成员4提交相对父提交的完整差异；不包含原SQL中的未变凭据常量 |
| git-execution-record.json | 联调阶段fetch、PR头引用获取及分支保护记录 |
| binding-stage-summary.json | 副本验证范围和原库迁移边界 |
| copy-official-b3-init.json | 独立副本原样执行13初始化脚本的输出 |
| copy-official-b3-rerun-guard.json | 非空账号表重复执行被56005拒绝 |
| copy-pk-completion.json | 副本主键元数据遗漏及补齐记录 |
| copy-secure-credentials.json | 副本安全初始化统计；仅账号数及独立盐/哈希数量，不含任何盐或哈希值 |
| copy-self-test.json | 副本原始14自测逐项结果及错误；不替代原库完整结构验证 |
| original-self-test-before.json | 原库迁移前自测，含原B3覆盖失败和M4数据缺失 |
| original-self-test-after.json | 原库迁移后自测：24通过、7失败及57002错误 |
| original-verify-b3-cli-command.json | 原库正式CLI命令、目标测试库、正常启动门禁与退出码；只引用仓库外文件路径 |
| original-verify-b3-cli.json | 原库28账号逐项脱敏结果 |
| original-verify-b3-cli.log | 原库CLI脱敏输出 |
| copy-verify-b3-cli-command.json | 副本正式CLI命令、目标测试库、正常启动门禁与退出码 |
| copy-verify-b3-cli.json | 副本28账号逐项脱敏结果 |
| copy-verify-b3-cli.log | 副本CLI脱敏输出 |
| test-only-binding-migration.json | 三个测试账号的新旧机构绑定及迁移方法 |
| permissions-results.json | 机构读写、双向越权、责任方提交及回滚检查明细 |
| business-before.json | 原库21张非账号业务表的行数和逐行聚合SHA256 |
| business-after-binding.json | 绑定调整后的业务表哈希，和before一致 |
| business-after-permissions.json | 全部权限探针回滚后的业务表哈希，和before一致 |
| final-database-check.json | 最终22表、40个可信启用外键、3触发器、账号状态及实际机构 |
| credential-scan.json | 真实28密码的内存匹配检查及归档排除检查统计，不含密码 |

完整说明见[补充联调阶段报告](../../../2026-11-27_B3_org_binding_supplement.md)和[阶段性验收记录](../../../2026-11-27_member2_stage_acceptance.md)。本目录不含b3-accounts.json、完整身份清单、DPAPI密文、明文密码、盐/密码哈希值、数据库备份或连接凭据。两个CLI命令中的仓库外路径仅用于追溯，不表示相应文件已归档。

归档检查只读取上述证据文件，不连接任何数据库。SHA256SUMS.txt记录本目录除自身以外各文件的SHA256；.gitattributes禁止归档文件的换行转换，使工作区、Git对象和后续Windows检出的哈希一致。原始diff保留单空格空白上下文行，仅对该证据关闭空白检查，不改写原始差异。本轮提交的完整文件清单可用 `git show --name-only <归档提交SHA>` 获取。联调阶段记录中的“未commit/push”描述当时执行状态，本次后续归档提交和正常推送由Git历史记录。
