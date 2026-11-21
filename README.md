# elderly-care-platform

社区居家养老智慧服务平台数据库课程设计（SQL Server 2022，`dbo` 架构）。

## 模块状态

| 成员 | 模块 | 表 / 字段 | 仓库状态 |
|---|---|---|---|
| 成员1 | 老人档案与能力评估 | 5 表 / 39 字段（含公共 `service_org`） | SQL、数据字典、测试数据已提交 |
| 成员2 | 服务下单与派单 | 3 表 / 34 字段 | SQL、数据字典、逻辑/物理设计已提交 |
| 成员3 | 护工与排班管理 | 4 表 / 32 字段 | 已合并 main |
| 成员4 | 健康监测与应急响应 + 公共账号表 | M4 3 表 / 32 字段；`sys_user` 1 表 / 18 字段 | SQL、Markdown 文档、测试数据已提交 |
| 成员5 | 补贴核算与质量监管 | 6 表 / 90 字段 | SQL 01–07 已提交，待整合 |

## 公共共享表分工

| 公共表 | 作用 | 负责人 | 当前状态 |
|---|---|---|---|
| `elder_profile` | 老人基本档案 | 成员1 | 已有 DDL |
| `service_org` | 养老服务机构信息 | 成员1 | 已有 DDL |
| `service_item` | 服务项目目录 | 成员2 | 已有 DDL |
| `sys_user` | 公共用户账号及人员身份 | 成员4 | 正式 DDL + 基础/补充账号脚本 |

其他模块使用公共表时只引用主键，不再各自建用户表、机构表或服务项目表。

## 当前联调进度

- 五个模块数据库结构已整合并通过验收，首批 113 条基础数据已导入。
- 第二批数据准备中：15 家机构、16 位阳光社区老人、20 条评估/照护计划；28 个测试账号待初始化。
- 成员5 的 01–07 已完成 10 项测试，全部 PASS。

## 整合执行顺序（按成员5 实测）

> 命令行执行统一加 `-I`：`sys_user` 有筛选唯一索引，`QUOTED_IDENTIFIER OFF` 会报 Msg 1934。
> 示例：`sqlcmd -I -S localhost -d 数据库名 -i member4/09_sys_user.sql`

1. **成员1**：`member1/01_member1_tables.sql` → `03_member1_test_data.sql`
2. **成员3**：`member3/sql/01_M3_CreateTables.sql`（四表建表）
3. **成员2**：`member2/01_member2_tables.sql` → `02_member2_foreign_keys.sql` → `06_member2_procedures.sql`
4. **成员4**：`member4/09_sys_user.sql` → `10_sys_user_test_data.sql` → `12_sys_user_business_accounts.sql` → `01_schema.sql` → `02_views_procedures.sql` → `04_test_data.sql` → `03_queries.sql`
5. **成员3**：`member3/sql/05_M3_TestData-v2.sql` 的 BASE 阶段
6. **成员5**：`member5/01` → `02` → `06` → `05`
7. **成员2**：`member2/03_member2_test_data.sql` 灌订单
8. **成员5**：`member5/03` → `04` → `07`

成员4 的详细说明见 [`member4/README.md`](member4/README.md)，账号与角色见 [`member4/09-公共账号与人员身份.md`](member4/09-公共账号与人员身份.md)。

## 已知缺口

- 成员3 已合并 main；成员5 的 01–07 已提交，仍需按整合库顺序联调。
- `sys_user.caregiver_id → caregiver(caregiver_id)` 外键在 `09` 建表时自动补；如果当时 `caregiver` 不存在，再由 `member4/11_sys_user_caregiver_fk.sql` 补。
- 数据范围采用方案 A：只按 `elder_id` / `caregiver_id` / `org_id` 限制；社区、街道、区县暂不做精确过滤。
- 成员3 的整合报告是合并前的历史记录，其中“缺 sys_user”已由 `member4/09_sys_user.sql` 解决。
- 28 个测试账号的分配待成员2/4 确认；命令行执行统一 `sqlcmd -I`。
- 所有 SQL 需在测试库按顺序执行；仓库暂未附执行截图。
