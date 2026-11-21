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

## 整合执行顺序

1. **成员1**：`member1/01_member1_tables.sql` → `03_member1_test_data.sql`
2. **成员2**：`member2/01_member2_tables.sql` → `02_member2_foreign_keys.sql` → `06_member2_procedures.sql` → `03_member2_test_data.sql`
3. **成员3**：四表（已合并 main），按 `member3/sql/README.md` 执行
4. **成员4**：
   - `member4/09_sys_user.sql`
   - `member4/10_sys_user_test_data.sql`
   - `member4/12_sys_user_business_accounts.sql`（护工/老人/家属/机构/审核补充账号）
   - `member4/01_schema.sql`
   - `member4/02_views_procedures.sql`
   - `member4/04_test_data.sql`
   - `member4/03_queries.sql`
   - 如果 `09` 执行时 `caregiver` 还不存在：`member4/11_sys_user_caregiver_fk.sql`
5. **成员5**：`member5/01`–`07`，并完成跨模块外键联调

成员4 的详细说明见 [`member4/README.md`](member4/README.md)，账号与角色见 [`member4/09-公共账号与人员身份.md`](member4/09-公共账号与人员身份.md)。

## 已知缺口

- 成员3 已合并 main；成员5 的 01–07 已提交，仍需按整合库顺序联调。
- `sys_user.caregiver_id → caregiver(caregiver_id)` 外键在 `09` 建表时自动补；如果当时 `caregiver` 不存在，再由 `member4/11_sys_user_caregiver_fk.sql` 补。
- `service_org` 目前是养老服务机构表；街道/民政账号暂不强制 `org_id`，辖区范围后续由机构表扩展或应用层配置。
- 成员3 的整合报告是合并前的历史记录，其中“缺 sys_user”已由 `member4/09_sys_user.sql` 解决。
- 所有 SQL 需在测试库按顺序执行；仓库暂未附执行截图。
