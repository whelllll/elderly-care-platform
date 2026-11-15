# 成员2 服务下单与派单

社区居家养老智慧服务平台数据库课设。脚本以《成员2数据字典-v1》《成员1数据字典》《成员3数据字典》和《成员2+成员3协作规则-v1》为依据，面向 SQL Server 2022 或更新版本，使用 `dbo` 架构。三张业务表保持 `service_item` 7 列、`service_order` 13 列、`dispatch_record` 7 列。

## 文件与执行顺序

| 顺序 | 文件 | 内容 |
| --- | --- | --- |
| 1 | `01_member2_tables.sql` | 三张表、内部外键、默认值、检查约束、有效派单筛选唯一索引 |
| 2 | `02_member2_foreign_keys.sql` | 四条跨模块外键。独立路径可以创建测试专用父表和成员3接口表 |
| 3 | `06_member2_procedures.sql` | 创建订单、派单与状态流转、签到围栏校验 |
| 4 | `03_member2_test_data.sql` | 原子写入、可重跑的 20 个服务项目、20 个订单、20 条派单 |
| 5 | `04_member2_queries.sql` | 两个三表查询，涵盖窗口函数、最新派单与按项目汇总 |
| 6 | `05_member2_views.sql` | 订单明细、有效派单和服务项目汇总视图 |
| 7 | `07_member2_tests.sql` | 部署验收、样例计数和独立业务测试 |

在 SSMS 中逐个打开脚本。每个查询窗口都要在数据库下拉框选择同一个目标库，整份执行。遇到报错先解决当前脚本，再继续下一份。若库中已有早期版本的同名业务表，请使用新测试库，或由整合负责人先迁移旧表。

## 路径 A 在独立测试库运行

1. 在 SSMS 新建专用数据库 `Member2_Standalone_Test`。也可以在 `master` 中执行下面这一句。
   
   ```sql
   CREATE DATABASE Member2_Standalone_Test;
   ```

2. 把窗口切换到该库，运行 `01`。打开 `02`，只在本地查询窗口把 `DECLARE @Standalone BIT = 0;` 改为 `DECLARE @Standalone BIT = 1;` 后运行。脚本创建仅供独立验收的父表和接口表，并建立四条跨模块外键。
3. 依次运行 `06 → 03 → 04 → 05 → 07`。独立路径的 `03` 无需修改。它在测试库创建模拟老人、护工、证书和开放班次，读取数据库实际分配的 ID。样例含待派单、待接单、待服务和已取消订单，也有拒单、撤回的历史记录。
4. 再跑一次 `03` 和 `07`。样例计数仍应为 `20 / 20 / 20`，独立验收应输出 `PASS 部署验收` 和 `PASS 12 项独立业务及约束用例`。在全新独立库，三个视图的预期行数依次为 `20 / 3 / 20`。

独立用例覆盖金额与时长快照、社区精确匹配、资质过期、左闭右开区间、服务重叠、班次累计容量、非法围栏、外键、重复派单、改派回滚、签到前置条件和订单状态流转。用例结束后测试临时写入会回滚，自增编号可能出现空号。样例本身保留，便于查询和答辩演示。

## 路径 B 在小组整合测试库运行

1. 用整合测试库部署成员2的 `01`，并根据组内顺序部署成员1的 `elder_profile`、成员3的 `caregiver`、`caregiver_certificate`、`caregiver_schedule`、`work_record`。基础表先建，引用双方的外键后建。成员3如果把引用成员2的外键写在建表语句里，成员2的 `01` 要先执行。成员1的 `care_plan` 建表或设外键前也要确保 `elder_profile` 与 `caregiver` 已存在。
2. 运行 `02`，保留 `@Standalone = 0`。如果成员3已经建立语义一致的可信外键，脚本按子列和父列识别并复用。成员1、3的模块内部及其它跨模块外键由各模块维护。
3. 运行 `06`。如需 20／20／20 整合样例，先运行下方 SQL 核对候选记录，然后把 `03` 的 `@AllowIntegrationSeed` 改为 `1`，填写 `@ElderID`、`@CaregiverID`、`@ServiceID` 和未来的 `@AppointmentTime`。请使用约定的测试档案。预约时段须完整落在一个开放班次内，有可用容量、无重叠派单，项目须上架且护工资质覆盖预约日期。整合样例用同一组记录和同一空闲时段，每条派单生成后即撤回，释放名额并保留历史。任何一步失败，整批回滚。
4. 运行 `04 → 05 → 07`。如果跳过 `03`，`07` 仍可验收表、外键、视图和存储过程。已运行 `03` 时应看到 `20 / 20 / 20`。整合库由组员用真实联调数据复测业务流程。

```sql
SELECT elder_id, elder_name, community_name
FROM dbo.elder_profile WHERE archive_status = N'正常';

SELECT c.caregiver_id, c.caregiver_name, c.service_area,
       s.service_id, s.service_name, s.duration, cert.valid_from, cert.valid_to,
       sh.schedule_id, sh.start_time, sh.end_time, sh.max_orders
FROM dbo.caregiver AS c
JOIN dbo.caregiver_certificate AS cert ON cert.caregiver_id = c.caregiver_id
JOIN dbo.service_item AS s ON s.service_id = cert.service_id
JOIN dbo.caregiver_schedule AS sh ON sh.caregiver_id = c.caregiver_id
WHERE c.employment_status = N'在岗' AND cert.certificate_status = N'有效'
  AND s.status = N'上架' AND sh.schedule_status = N'开放' AND sh.end_time > SYSDATETIME()
ORDER BY c.caregiver_id, sh.start_time, s.service_id;
```

四条跨模块外键均为 `INT`、`NO ACTION`，启用并校验历史数据。

| 引用列 | 目标列 |
| --- | --- |
| `service_order.elder_id` | `elder_profile.elder_id` |
| `dispatch_record.caregiver_id` | `caregiver.caregiver_id` |
| `caregiver_certificate.service_id` | `service_item.service_id` |
| `work_record.dispatch_id` | `dispatch_record.dispatch_id` |

## 联调接口与约束

- `dbo.usp_M2_CreateOrder` 使用实际的老人及项目 ID，记录项目价格和时长快照，返回 `@OrderID OUTPUT`。预约不得早于下单时间。订单地址填 `清华园社区-12号楼301室` 这样的格式。派单时取第一个英文连字符前的社区名，与 `caregiver.service_area` 逐字符比较。
- `dbo.usp_M2_OrderAction` 支持 `DISPATCH` 派单、`REASSIGN` 改派、`ACCEPT` 接单、`REJECT` 拒单、`WITHDRAW` 撤回、`CANCEL` 取消、`START` 开始和 `COMPLETE` 完成。派单和改派传入目标 `@CaregiverID`。改派、接单、拒单、撤回、开始、完成还需把当前有效派单编号传入 `@DispatchID OUTPUT`。改派成功时该参数返回新编号。
- 派单事务检查在岗、服务上架、社区、预约日有效资质、开放班次、时段冲突和容量。时间使用 `[开始, 结束)`。待接单与已接单占容量，拒绝和撤回释放容量，完成后保留已接单记录及其班次容量。改派先撤回再新建，两步一起提交或一起回滚。请通过过程更新订单与派单，过程使用同一事务锁，调用方若已开启事务，发生错误时由调用方回滚。
- 27 列版本的派单表没有 `schedule_id`。成员3创建工时记录前，按护工 ID 和订单预约区间匹配原班次，将编号写入 `work_record.schedule_id`。工时形成后优先使用该编号计入容量。为保留派单归属，联调时应保持已承接服务的班次时间、预约区间和时长快照稳定。开始服务要求存在匹配班次的签到记录。本版将有效签退和成员3审核通过作为完成确认。
- `dbo.usp_M2_CheckFence` 接收订单编号和签到位置字符串，返回 `@FenceResult`、`@DistanceM`。坐标为 WGS84 十进制度，按 `纬度,经度` 填写，例如 `39.9900000,116.3300000`。使用英文逗号。纬度范围 −90 至 90，经度范围 −180 至 180。订单三项围栏数据同时填写或同时为空。距离不超过半径判为 `通过`，超出判为 `未通过`，缺失或非法数据返回 `待校验`。成员3负责保存签到、签退、围栏结果及人工审核。

```sql
DECLARE @order_id INT = (
    SELECT order_id FROM dbo.service_order WHERE remark = N'M2:v1:order:01'
);
DECLARE @result NVARCHAR(10), @metres FLOAT;
EXEC dbo.usp_M2_CheckFence @order_id, N'39.9900000,116.3300000', @result OUTPUT, @metres OUTPUT;
SELECT @result AS fence_result, @metres AS distance_m;
-- 独立样例预期：通过，0 米。
```

## 验证 SQL

```sql
SELECT t.name AS table_name, COUNT(*) AS column_count
FROM sys.tables AS t
JOIN sys.columns AS c ON c.object_id = t.object_id
WHERE t.schema_id = SCHEMA_ID(N'dbo')
  AND t.name IN (N'service_item', N'service_order', N'dispatch_record')
GROUP BY t.name;

SELECT order_id, COUNT(*) AS active_dispatch_count
FROM dbo.dispatch_record
WHERE dispatch_status IN (N'待接单', N'已接单')
GROUP BY order_id HAVING COUNT(*) > 1;

SELECT TOP (5) * FROM dbo.vw_M2_OrderDetails ORDER BY order_id;
SELECT TOP (5) * FROM dbo.vw_M2_ActiveDispatch ORDER BY dispatch_id;
SELECT TOP (5) * FROM dbo.vw_M2_ServiceSummary ORDER BY order_count DESC, service_id;
```

首个结果的列数与数据字典一致，第二个结果应为零行。样例写入后的三个视图应能查询。

## 上传到 GitHub

1. 解压 ZIP，进入解压得到的 `member2` 目录。里面有 **7 个 SQL 文件和 1 个 README，共 8 个文件**。
2. 在 GitHub 打开小组仓库 `elderly-care-platform/member2`，选择 **Add file → Upload files**，将目录里的 8 个文件拖入页面。若 `member2/README.md` 已有占位内容且上传页拒绝同名文件，先上传 7 个 SQL 文件，再通过 README 页面右上角的编辑按钮替换内容。
3. 确认文件路径是 `member2/01_member2_tables.sql` 到 `member2/07_member2_tests.sql`，以及 `member2/README.md`。提交说明可填 `Add member2 SQL Server module`，按小组分支约定提交。
4. 提交后打开 `member2` 复核 8 个文件。可参考 [GitHub 文件上传步骤](https://docs.github.com/en/repositories/working-with-files/managing-files/adding-a-file-to-a-repository)。

## 验证环境

已在本机 SQL Server 2025 实跑。独立测试通过 12 项业务与约束用例，两次导入后样例数仍为 20／20／20。整合路径用符合接口的测试表演练，通过了非连续外部主键、复用既有外键及重复导入验证。成员1、3的正式 SQL 脚本和小组目标实例仍需按路径 B 联验。
