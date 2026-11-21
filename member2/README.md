# 成员2 服务下单与派单

社区居家养老智慧服务平台数据库课设，SQL Server 2022 或更新版本，使用 `dbo` 架构。本版以本目录《成员2数据字典.docx》为准，共3张业务表、34个字段（9／15／10）。保留旧库数据，不执行删除表或自动迁移；请使用新测试库验证。

## 文件与执行顺序

| 顺序 | 文件 | 内容 |
| --- | --- | --- |
| 1 | `01_member2_tables.sql` | 3张表、内部外键、主键、默认值、CHECK、UNIQUE 与索引 |
| 1a | `03_member2_service_items.sql` | 独立初始化20条服务项目；不依赖护工，不创建订单或派单，可重复执行 |
| 2 | `02_member2_foreign_keys.sql` | 3条本模块跨模块外键、2条成员3引用本模块的外键；可选独立测试模拟表 |
| 3 | `06_member2_procedures.sql` | 创建订单、派单与状态流转、签到围栏校验 |
| 4 | `03_member2_test_data.sql` | 各20条项目、订单、派单的可重跑样例 |
| 5 | `04_member2_queries.sql` | 2条三表关联复杂查询 |
| 6 | `05_member2_views.sql` | 订单明细、有效派单、服务项目汇总3个视图 |
| 7 | `07_member2_tests.sql` | 结构验收、32项独立测试，或8项正式接口整合测试 |

## 路径 A 独立测试

在 SSMS 新建一个空的普通数据库：

```sql
CREATE DATABASE Member2_Standalone_Test_v3;
```

1. 在 SSMS 的数据库下拉框选择 `Member2_Standalone_Test_v3`，执行 `01`。
2. 打开 `02`，仅在本地执行窗口把 `DECLARE @Standalone BIT = 0;` 改为 `DECLARE @Standalone BIT = 1;`，执行后生成模拟老人、护工、资质、排班、工时、整改限制接口。模拟表禁止放入小组正式库。
3. 按 `06 → 03 → 04 → 05 → 07` 的顺序执行，每个窗口均选择相同数据库。
4. 预期 `07` 输出 `20 / 20 / 20`、`PASS 部署验收`、32个独立测试的 PASS。再次执行 `03` 和 `07` 不应增加样例条数。独立测试的临时数据会回滚，自增编号可能出现空号。

如果已存在早期版本的同名表，`01` 会拒绝混用旧结构；不要删除历史库，另建上述 v3 测试库即可。

## 路径 B 小组整合测试

第一批数据导入先运行 `01_member2_tables.sql`，再运行 `03_member2_service_items.sql`。这个入口只写 `service_item`，不需要先运行 `02`、`06`、完整的 `03_member2_test_data.sql`，也不需要护工、老人或整改接口。

初始化结果会列出实际 `service_id` 与项目业务键。成员3可选用 `service_name = N'M2测试-上门保洁'`、`service_type = N'家政'`（30分钟、按次），填写其 `05_M3_TestData-v2.sql` 的 `@ServiceName`、`@ServiceType`；不要假定服务项目ID从1开始。20条项目中第20条是下架测试项目，第一批正常业务应选择上架项目。

重复运行只补缺失项目，不修改已有项目价格、时长或状态，不新增订单、派单。后续完整 `03_member2_test_data.sql` 复用相同的项目标识，不会再次插入这20条项目。完整03仍需显式填写合法老人、护工、项目和预约参数后才运行。

07正式分支支持仅有20条项目、尚无样例订单/派单的分阶段导入状态；独立分支仍要求20/20/20完整样例。

1. 各成员创建基础表。成员2的 `01` 已包含本模块两个内部外键，需先于引用服务项目和派单表的其他模块外键执行。
2. 成员1提供 `elder_profile`；成员3提供 `caregiver`、`caregiver_certificate`、`caregiver_schedule`、`work_record`；成员5提供 `rectification`（派单限制校验）。运行 `02` 时保持 `@Standalone = 0`，不会创建模拟表。
3. 执行 `06`、`04`、`05`、`07` 进行整合部署。07的正式分支要求成员3正式表、成员4正常可用的民政/街道角色账号，以及成员5的建表、外键、视图、整改创建/复查过程和同步触发器。该分支执行8项真实接口测试，测试夹具统一回滚，不执行独立分支的接口删除/替换故障注入。
4. 如需生成整合样例，先确认是专用测试库，在 `03` 中设置 `@AllowIntegrationSeed = 1`，填入已核对的老人、护工、服务项目 ID 和未来预约时间。老人社区与护工区域须一致，预约须完整落在开放班次内且资质有效。样例派单后撤回，释放容量。

本模块5条外键均为 `INT`、`NO ACTION`（2条内部、3条跨模块）：

| 引用方 | 被引用方 |
| --- | --- |
| `service_order.service_id` | `service_item.service_id` |
| `service_order.elder_id` | `elder_profile.elder_id` |
| `dispatch_record.order_id` | `service_order.order_id` |
| `dispatch_record.caregiver_id` | `caregiver.caregiver_id` |
| `dispatch_record.schedule_id` | `caregiver_schedule.schedule_id` |

`02` 还检查成员3的 `caregiver_certificate.service_id → service_item.service_id` 和 `work_record.dispatch_id → dispatch_record.dispatch_id`，已存在语义等价的可信外键时复用，不重复创建。成员5的补贴政策、申报明细、质量抽查外键由成员5维护。

## 业务接口

- `usp_M2_CreateOrder`：传入老人、项目、预约时间、地址和下单渠道（`@OrderChannel`，默认电话），返回 `@OrderID OUTPUT`。只允许上架项目；按次按指导价计费，按小时按指导价 × 服务时长分钟 / 60 计费，并保存金额和时长快照。地址格式为“社区名称-详细地址”，社区必须与老人档案一致。经纬度和半径同时为空或同时填写。
- `usp_M2_OrderAction`：支持 `DISPATCH`、`REASSIGN`、`ACCEPT`、`REJECT`、`WITHDRAW`、`CANCEL`、`START`、`COMPLETE`。首次派单和改派传入目标护工 `@CaregiverID`；改派、接单、拒单、撤回、开始和完成须传入当前有效派单编号 `@DispatchID OUTPUT`。再次派单必须通过 `@Reason` 提供改派原因；新记录保存 `reassign_reason`，旧记录保留。
- 派单事务检查护工在岗、社区、有效资质、整改接单限制、唯一开放班次、时间冲突和容量，并保存所属 `schedule_id`。容量直接按 `schedule_id` 统计；待接单与已接单占容量，拒绝与撤回释放容量；已完成订单仍保留已接单记录。跨模块并发修改规则需由小组联调统一，应用层应通过过程操作而非绕开过程直接写入。
- `COMPLETE` 需成员3提供匹配派单及班次的签到、签退和审核通过记录，并由调用方在实际取得家属确认或双方签字后传入 `@Confirmed = 1` 和 `@ServiceRecord`。过程写入服务记录及订单确认状态，再原子更新完成状态。不得用工时审核代替家属确认。
- `usp_M2_CheckFence`：输入订单编号与 WGS84 “纬度,经度”字符串，返回围栏结果及距离（米），缺失或非法数据返回“待校验”。成员3负责保存工时及人工审核。
- 派单及改派在同一事务内先调用成员5的 `usp_M5_LockScope`，按机构→护工顺序加锁，再取得订单/派单保护锁并查询 `vw_M5_CaregiverBlocked`、`vw_M5_OrgBlocked`；全部校验通过后才写派单。改派的冲突和容量检查只排除本次原派单。成员2不自行用 `UPDLOCK` 锁机构或护工，保留全局事务应用锁。`ACCEPT`、`START`、`COMPLETE` 不做整改限制检查。
- 整改标志由成员5维护，member2通过两个限制视图判定；补贴项目资格由 `service_item.is_subsidizable` 表示，具体补贴依赖成员5的政策与工时。

## GitHub 提交

提交 `member2` 中七个 SQL 脚本、README、数据字典、局部 E-R 图和逻辑及物理结构设计文档。按小组分支约定提交，不包含独立测试数据库备份或模拟父表的正式部署结果。

## 验证状态

06、07及07内的正式动态批次已通过SQL Server T-SQL语法解析；32项独立测试已实际通过。8项真实接口测试在诊断环境中通过并可重复执行，诊断环境临时修正了成员5视图的一个括号，未修改成员5源文件，不能据此宣称仓库原样部署通过。

已知正式部署阻碍：当前02的独立模拟机构插入在正式机构表下会发生编译冲突（213）；成员5的05在`GROUP BY caregiver_id;');`处有多余右括号（102）。本轮未修改这两个文件。它们不影响先通过新入口导入服务项目，但完整整合部署前仍需处理。

服务项目独立入口已在无护工、无派单过程的新隔离库验证：首次新增20条，重复新增0条，订单与派单始终为0；调用方事务可回滚。随后按成员3正式BASE脚本验证了22名护工、24条证书和22条排班的导入，解除项目与护工测试数据的前置依赖冲突。
