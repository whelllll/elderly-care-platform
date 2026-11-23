# 成员5 补贴核算与质量监管

社区居家养老智慧服务平台数据库课设，SQL Server 2019 及以上，统一使用 `dbo` 架构。本目录共 **6 张业务表、91 个字段（17／18／10／12／18／16）**，另含 **4 个视图、2 个触发器、9 个存储过程、13 项验收测试**。字段口径与《成员5 数据字典》一致，跨模块接口按 `成员2+成员5协作规则` 与群内公共表决议对齐。

## 文件与执行顺序

| 顺序 | 文件 | 内容 |
| --- | --- | --- |
| 1 | `01_member5_tables.sql` | 6 张表、主键、默认值、CHECK、UNIQUE 与索引 |
| 2 | `02_member5_foreign_keys.sql` | 11 条跨模块外键；父表缺失时跳过并列出待办，不中断 |
| 3 | `06_member5_procedures.sql` | 明细校验触发器 + 防重复申报、汇总回写、限制接单联动 |
| 4 | `03_member5_test_data.sql` | 每表 20 条可重跑样例（带 `M5:v1:*` 标记，重复执行不产生重复行） |
| 5 | `04_member5_queries.sql` | 补贴追溯与拨付进度的多表复杂查询 |
| 6 | `05_member5_views.sql` | 申报与拨付进度、补贴明细追溯、限制接单护工 |
| 7 | `07_member5_tests.sql` | 结构验收 + 13 项业务测试，输出 PASS／FAIL 汇总 |

`03` 与 `07` 依赖成员1／2／4 的公共数据，须在其测试数据导入之后执行；整合库中若已有足量数据，可跳过 `03` 直接跑 `07`。

整合库的完整导入顺序：**成员1 建表+数据 → 成员2 建表+数据 → 成员3 建表+数据 → 成员4 `09`+`10` → 成员5 `01`→`02`→`06`→`03`→`04`→`05`→`07`**。

## 依赖的公共表

| 表 | 负责人 | 本模块用法 |
| --- | --- | --- |
| `elder_profile` | 成员1 | `subsidy_application.elder_id` |
| `service_org` | 成员1 | `rectification.org_id`，删除规则 NO ACTION |
| `service_item` | 成员2 | `subsidy_policy.service_item_id` → `service_id`；只挂 `is_subsidizable = 1` 的项目 |
| `service_order` | 成员2 | `subsidy_application_item.order_id`、`quality_inspection.order_id` |
| `caregiver` | 成员3 | 抽查对象、整改责任护工 |
| `work_record` | 成员3 | `subsidy_application_item.work_id` → `work_id`（`02` 自动兼容 `work_hour` 命名） |
| `sys_user` | 成员4 | 审核人、抽查人、复查人；已交付（18 字段，`user_id INT` 主键），4 条外键可正常挂载 |

## 业务规则的落点

| 规则 | 实现位置 |
| --- | --- |
| 同老人·同政策·同周期不得重复申报 | `UQ_M5_app_once` 唯一约束；跨政策同项目由 `usp_M5_CreateApplication` 拦截 |
| 补贴 + 自付 ≤ 服务金额 | 触发器 `TR_M5_Item_Guard` |
| 申报金额可追溯到订单与工时 | 明细同时外键 `order_id`、`work_id`；缺工时自动置 `verify_result = '工时缺失'` |
| 不可补贴项目不得计入 | 触发器校验 `service_item.is_subsidizable` |
| 补贴方式与计价单位匹配 | `usp_M5_CreateApplication` 校验 `service_item.charge_unit` ↔ `subsidy_mode`（错误号 52116） |
| 抽查对象互斥（订单／护工二选一） | `CK_M5_insp_object_exclusive` |
| 评分等级 | 计算列 `score_level`（PERSISTED），不参与业务写入 |
| 整改未完成限制接单 | `rectification.restrict_flag` + `usp_M5_SyncRestrictFlag`；派单模块查 `vw_M5_CaregiverBlocked` |

## 与成员2 的计价口径约定

| `service_item.charge_unit` | 允许的 `subsidy_policy.subsidy_mode` | 金额算法 |
| --- | --- | --- |
| 次 | 按次定额 / 按比例 / 按月定额 | 每次按 `subsidy_standard` 定额，或按比例乘订单金额 |
| 小时 | 按工时 / 按比例 / 按月定额 | `subsidy_standard × valid_hours`，故明细必须回填有效工时 |

`按月定额` 为包干口径，与计价单位无关，两种项目均可用。不匹配的申报由 `usp_M5_CreateApplication` 以 52116 拒绝，验收脚本 T7 覆盖该场景。

## 公共账号引用约定（成员4 sys_user）

本模块的审核人、抽查人、复查人不新建用户，统一引用成员4 的 `sys_user.user_id`。测试数据按他的账号取值：

| user_id | 账号 | 角色 | 本模块用途 |
| --- | --- | --- | --- |
| 2 | comm_admin | COMMUNITY_ADMIN | 社区初审 `auditor_id` |
| 3 | street_sup | STREET_SUPERVISOR | 街道复审、整改复查 `reviewer_id` |
| 4 | civil_sup | CIVIL_SUPERVISOR | 民政抽查 `inspector_id` |
| 1 / 5 | admin / org_mgr | SYS_ADMIN / ORG_MANAGER | 不参与本模块审核链，仅作备用 |

`03` 开头会校验 `sys_user` 是否存在 user_id 2/3/4，缺失直接 THROW 52205／52206，避免外键报错难排查。

## 给成员2 派单模块的接口

```sql
-- 返回当前处于限制接单状态的护工，restrict_flag = 'Y' 即不得分配新订单
SELECT caregiver_id, blocked_count, earliest_deadline, latest_problem
FROM dbo.vw_M5_CaregiverBlocked;
```

## 联调状态

| 项 | 状态 |
| --- | --- |
| 跨模块外键 | 11 条已配置，`sys_user` 到位后可全部挂载 |
| `sys_user` | 已交付（成员4 PR #2）：18 字段、`user_id INT` 主键、8 个角色；`09` 建表 + `10` 账号数据 |
| 成员3 的 `caregiver` / `work_record` | 分支已提交，**尚未合并进 main**；未合并前 `02` 会跳过 2 条护工外键 |
| `settle_cycle` 同名不同义 | 政策侧为周期单位、申报侧为账期，联调时不要等值关联 |

## 已知待办

1. **`settle_cycle` 同名歧义**：`subsidy_policy.settle_cycle` 表示周期单位（月／季／半年／年，`CHAR(6)`），`subsidy_application.settle_cycle` 表示账期（`yyyy-mm`，`CHAR(7)`）。若评审要求消除同名，可把政策侧改名为 `cycle_unit`。
2. **成员3 分支合并**：`caregiver`、`work_record` 仍在 `feature-member3-initial-ddl` 分支，合并后重跑 `02` 自动挂载护工与工时外键。
3. **重跑顺序**：成员4 交付后，按 `02 → 03 → 07` 重跑一遍，确保外键与新账号数据同时生效。
