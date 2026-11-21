# 成员5 补贴核算与质量监管

社区居家养老智慧服务平台数据库课设，SQL Server 2019 及以上，统一使用 `dbo` 架构。本目录共 **6 张业务表、91 个字段（17／18／10／12／18／16）**，另含 **4 个视图、2 个触发器、6 个存储过程、10 项验收测试**。字段口径与《成员5 数据字典》一致，跨模块接口按 `成员2+成员5协作规则` 与群内公共表决议对齐。

## 文件与执行顺序

| 顺序 | 文件 | 内容 |
| --- | --- | --- |
| 1 | `01_member5_tables.sql` | 6 张表、主键、默认值、CHECK、UNIQUE 与索引（含旧库补列脚本） |
| 2 | `02_member5_foreign_keys.sql` | 11 条跨模块外键；父表缺失时跳过并列出待办，不中断 |
| 3 | `06_member5_procedures.sql` | 2 个触发器 + 6 个存储过程（校验、防重复申报、加锁、整改流转） |
| 4 | `05_member5_views.sql` | 进度、追溯、机构级限制、护工限制接单四个视图 |
| 5 | `03_member5_test_data.sql` | 每表 20 条可重跑样例（带 `M5:v1:*` 标记，重复执行不产生重复行） |
| 6 | `04_member5_queries.sql` | 补贴追溯审计、机构与护工质量画像两条多表复杂查询 |
| 7 | `07_member5_tests.sql` | 结构验收 + 10 项业务测试，输出 PASS／FAIL 汇总 |

`03` 与 `07` 依赖成员1／2／4 的公共数据，须在其测试数据导入之后执行；整合库中若已有足量数据，可跳过 `03` 直接跑 `07`。

整合库的完整导入顺序：**成员1 建表+数据 → 成员2 建表+数据 → 成员3 建表+数据 → 成员4 `09`+`10` → 成员5 `01`→`02`→`06`→`05`→`03`→`04`→`07`**。

## 依赖的公共表

| 表 | 负责人 | 本模块用法 |
| --- | --- | --- |
| `elder_profile` | 成员1 | `subsidy_application.elder_id` |
| `service_org` | 成员1 | `rectification.org_id`，删除规则 NO ACTION；机构级限制的加锁对象 |
| `service_item` | 成员2 | `subsidy_policy.service_item_id` → `service_id`；只挂 `is_subsidizable = 1` 的项目 |
| `service_order` | 成员2 | `subsidy_application_item.order_id`、`quality_inspection.order_id`；**只读，整改与限制不改订单** |
| `caregiver` | 成员3 | 抽查对象、整改责任护工；机构级限制按 `org_id` 展开到人 |
| `work_record` | 成员3 | `subsidy_application_item.work_id` → `work_id`（`02` 自动兼容 `work_hour` 命名） |
| `sys_user` | 成员4 | 审核人、抽查人、复查人（18 字段，`user_id INT` 主键） |

## 业务规则的落点

| 规则 | 实现位置 |
| --- | --- |
| 同老人·同政策·同周期不得重复申报 | `UQ_M5_app_once` 唯一约束；跨政策同项目由 `usp_M5_CreateApplication` 拦截 |
| 补贴 + 自付 ≤ 服务金额 | 触发器 `TR_M5_Item_Guard` |
| 申报金额可追溯到订单与工时 | 明细同时外键 `order_id`、`work_id`；缺工时自动置 `verify_result = '工时缺失'` |
| 不可补贴项目不得计入 | 触发器校验 `service_item.is_subsidizable` |
| 补贴方式与计价单位匹配 | `usp_M5_CreateApplication` 校验 `service_item.charge_unit` ↔ `subsidy_mode`（52116） |
| 抽查对象互斥（订单／护工二选一） | `CK_M5_insp_object_exclusive` |
| 评分等级 | 计算列 `score_level`（PERSISTED），不参与业务写入 |
| **整改未完成限制接单** | `rectification.restrict_flag`，由触发器 `TR_M5_Rect_SyncFlag` 同事务同步 |
| **机构级限制：机构受限则旗下护工全部禁新单** | `rectification.rectify_scope = N'机构'` + `vw_M5_CaregiverBlocked`（按 `org_id` 展开）/ `vw_M5_OrgBlocked` |
| **限制只影响新派单与改派，已接订单继续完成** | 本模块全程不更新 `service_order`；`07` 的 T10 用校验和断言订单表零变化 |

### 整改对象的两级口径

| `rectify_scope` | `caregiver_id` | 含义 | 限制范围 |
| --- | --- | --- | --- |
| `护工` | 必填 | 护工级整改，责任落到个人 | 仅该护工不能接新单 |
| `机构` | 必须为空 | 机构级整改，责任由机构承担 | 该机构下**所有护工**不能接新单 |

两条 CHECK 强制互斥（`CK_M5_rect_scope`、`CK_M5_rect_scope_target`），不会出现「说机构级却挂着某个护工」的脏数据。

## 事务与并发：与成员2 的统一约定

**加锁顺序统一为：先机构 `service_org`，后护工 `caregiver`。** 双方都按此顺序，才不会交叉等待。

| 场景 | 加锁与事务 |
| --- | --- |
| 本模块新增整改 `usp_M5_CreateRectification` | 开事务 → `usp_M5_LockScope` 锁机构 → 锁护工 → INSERT 整改（触发器同步标志）→ 提交 |
| 本模块整改复查 `usp_M5_ReviewRectification` | 开事务 → 同序加锁 → UPDATE 状态与结论 → 触发器同步标志 → 读回 `restrict_flag` → 提交 |
| 成员2 派单 / 改派 | 开事务 → `usp_M5_LockScope` → 查 `vw_M5_CaregiverBlocked` / `vw_M5_OrgBlocked` → 无命中才写 `dispatch_record` → 提交 |

两个过程都采用「外层有事务则并入、没有才自己开」的写法，因此可以被更大粒度的业务事务包住，锁会一直持有到最外层提交。

**已与成员2 对齐的口径（派单／改派同一套）：**

1. 派单和改派都调用同一个 `usp_M5_LockScope`，加锁顺序固定「先 `service_org`、后 `caregiver`」；
2. 顺序固定为：`BEGIN TRAN` → `usp_M5_LockScope` → 查 `vw_M5_CaregiverBlocked` / `vw_M5_OrgBlocked` → 无命中才写 `dispatch_record` → `COMMIT`；
3. **已接订单的后续状态流转（接单、开始服务、完成、评价等）不再做整改限制判断**，本模块也不改写 `service_order`，两边都不会因为整改状态把在途订单卡住；
4. 因此 `usp_M5_LockScope` 是双方共用的唯一加锁入口，成员2 侧不要再自己写 `WITH (UPDLOCK)` 锁 `service_org` / `caregiver`，否则顺序一旦不一致仍可能死锁。

`usp_M5_LockScope` 参数约定：`@org_id` 必填（机构级整改时也用它定位机构）、`@caregiver_id` 可空（为空只锁机构）、输出 `@locked` 与 `@reason`；必须在外层事务内调用，过程内部不自行开事务、不提交（未开事务调用直接 `THROW 52150`）。

**为什么「加锁 → 查视图 → 写单」必须在同一个事务里**：`usp_M5_LockScope` 对 `service_org` / `caregiver` 行加的是 `UPDLOCK + HOLDLOCK`，而 `usp_M5_CreateRectification` 也是先锁同一批行、再 INSERT 整改单。两边抢同一行的 U 锁，于是「整改提交」与「查视图 + 写派单」天然互斥，不会出现“刚查完还没受限、整改单随即插入”的漏判。一旦把加锁和查视图拆成两个事务，这层互斥就没了，机构级限制会在极端并发下漏判。

`usp_M5_LockScope` 可直接复用：

```sql
BEGIN TRAN;

DECLARE @locked BIT, @reason NVARCHAR(100);
EXEC dbo.usp_M5_LockScope @org_id = @org_id, @caregiver_id = @caregiver_id,
                          @locked = @locked OUTPUT, @reason = @reason OUTPUT;

IF @locked = 0                      -- 机构/护工不存在或护工不属于该机构
BEGIN
    ROLLBACK;
    THROW 52001, @reason, 1;
END;

IF EXISTS (SELECT 1 FROM dbo.vw_M5_CaregiverBlocked WHERE caregiver_id = @caregiver_id)
BEGIN                               -- 护工级或机构级限制，均在此命中
    ROLLBACK;
    THROW 52002, N'该护工处于整改限制期，不得新派单或改派。', 1;
END;

-- 写入 dispatch_record … 然后 COMMIT
```

> 旧订单不受影响：限制状态只在「派新单 / 改派」时被查询，已存在的订单不校验、不改写，继续按原状态流转。

### 关于 `restrict_flag` 的同步

`TR_M5_Rect_SyncFlag` 在 `rectification` 的 INSERT／UPDATE 之后自动处理：

- `rectify_status = '复查通过'` → `restrict_flag = 'N'`，并补 `release_time`
- 其余状态（待整改／整改中／待复查／复查不通过／逾期未改）→ `restrict_flag = 'Y'`，清空 `release_time`

因为是同一条语句内的触发器，**它天然与业务写入同事务**，不存在「状态改了、标志没改」的中间态，也不依赖调用方是否记得加一步。

`usp_M5_SyncRestrictFlag` 因此降级为**回填／修复工具**（`@rectify_id` 单条，或 `@all = 1` 全表），不自行开启事务——回答成员2 的问题：正常流程已不需要外层事务额外包一层。

## 给成员2 派单模块的接口

```sql
-- ① 护工维度：命中即禁新单。机构级限制会把该机构所有护工一并列出（block_level = '机构级'）
SELECT caregiver_id, blocked_count, earliest_deadline, latest_deadline, block_level, latest_problem
FROM dbo.vw_M5_CaregiverBlocked
WHERE caregiver_id = @caregiver_id;

-- ② 机构维度：派单前若拿到的是机构，可直接判断该机构是否整体受限
SELECT org_id, blocked_count, earliest_deadline, latest_problem
FROM dbo.vw_M5_OrgBlocked
WHERE org_id = @org_id;
```

`block_level` 取值：`护工级`（仅个人受限）、`机构级`（仅因机构受限）、`护工+机构`（两重受限）。

## 与成员2 的计价口径约定

| `service_item.charge_unit` | 允许的 `subsidy_policy.subsidy_mode` | 金额算法 |
| --- | --- | --- |
| 次 | 按次定额 / 按比例 / 按月定额 | 每次按 `subsidy_standard` 定额，或按比例乘订单金额 |
| 小时 | 按工时 / 按比例 / 按月定额 | `subsidy_standard × valid_hours`，故明细必须回填有效工时 |

`按月定额` 为包干口径，与计价单位无关，两种项目均可用。不匹配的申报由 `usp_M5_CreateApplication` 以 52116 拒绝，验收脚本 T7 覆盖该场景。

## 公共账号引用约定（成员4 sys_user）

本模块的审核人、抽查人、复查人不新建用户，统一引用成员4 的 `sys_user.user_id`。

成员4 的 `10_sys_user_test_data.sql` 已改为**按 username 插入、`user_id` 交由 IDENTITY 生成**，`user_id 1..5` 的假设不再成立。`03` 因此改为**按角色动态取号**，脚本本身不写死任何 `user_id`：

| 本模块用途 | 需要的账号 | 定位方式 |
| --- | --- | --- |
| 社区初审 `auditor_id` | `COMMUNITY_ADMIN`（comm_admin） | `role_code` 优先，用户名兜底 |
| 街道复审、整改复查 `reviewer_id` | `STREET_SUPERVISOR`（street_sup） | 同上 |
| 民政抽查 `inspector_id` | `CIVIL_SUPERVISOR`（civil_sup） | 同上 |

取号逻辑（`03` 第 0.1 节）：先按 `role_code` 找，同一角色多账号时取「状态正常优先、`user_id` 最小」的一个；角色值对不上再退回 `username` 候选名单。三个账号任一缺失直接 `THROW 52206`，并把缺哪个角色写进报错信息，避免外键报错难排查（52205 仍用于 `sys_user` 表不存在）。

> 若成员4 后续调整账号命名，只需改 `03` 兜底名单里的 username，不用动表结构、外键和存储过程。

## 数据范围口径（组长确认的混合方案）

数据可见范围**不在数据库新增字段或表**，本模块 6 张表也不加 `scope`／`org_code` 之类的列：

- 老人、家属、护理员、机构负责人：按 `sys_user` 上的绑定身份（`elder_id`／`caregiver_id`／`org_id`）与机构范围过滤；
- 社区、街道、民政：各自的数据范围由后端配置确定，数据库层只保留归属字段（`rectification.org_id`、`subsidy_audit_log.auditor_org` 等）供条件拼接。

对本模块的影响：`05` 的视图只承担**整改限制判定**（`vw_M5_CaregiverBlocked`／`vw_M5_OrgBlocked`），不承担权限过滤；行级数据范围在查询层由后端参数控制。

## 测试数据与联调状态

`03` 的整改数据刻意让大部分已办结，保证联调时仍有可正常派单的护工：

- 机构级：`i = 3` 整改中、`i = 7` 复查不通过 → 2 个机构处于受限
- 护工级：`i = 13` 待整改、`i = 18` 整改中、`i = 16` 复查不通过 → 3 名护工受限

| 项 | 状态 |
| --- | --- |
| 跨模块外键 | 11 条，成员1／2／3／4 父表均已就绪，`02` 可全部挂载 |
| 成员3 的 `caregiver` / `work_record` | 已随 PR #1 合并进 main，护工外键与机构级限制视图可用 |
| `sys_user` | 已交付（成员4 PR #2）：18 字段、`user_id INT` 主键、8 个角色；`10` 已改为按 username 插入，`03` 改用角色动态取号 |
| `settle_cycle` 同名不同义 | 政策侧为周期单位、申报侧为账期，联调时不要等值关联 |
| 加锁入口 | 与成员2 统一为 `usp_M5_LockScope`，派单／改派都在事务内先加锁查视图再写单 |

## 已知待办

1. **`settle_cycle` 同名歧义**：`subsidy_policy.settle_cycle` 表示周期单位（月／季／半年／年，`CHAR(6)`），`subsidy_application.settle_cycle` 表示账期（`yyyy-mm`，`CHAR(7)`）。若评审要求消除同名，可把政策侧改名为 `cycle_unit`。
2. **旧库升级**：已建过 15 字段版 `rectification` 的库，重跑 `01` 会自动补 `rectify_scope` 列、两条 CHECK 与限制接单索引，历史 `caregiver_id IS NULL` 的行会被判为机构级。
3. **与成员2 的联合专项测试**：正常派单 → 机构级限制后拒单 → 复查通过后恢复派单，建议一次跑完三态，验证 `vw_M5_OrgBlocked` 与 `vw_M5_CaregiverBlocked` 结果一致。
