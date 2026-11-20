# 成员3 SQL部署与测试

基线：数据字典v4、逻辑结构v3，四表32字段。成员1/2整合脚本要求SQL Server 2022+；成员3单模块基础脚本支持SQL Server 2016+。选择专用用户测试库执行，不删除已有数据或重复覆盖部署对象。

## 正式文件与顺序

| 文件 | 用途与当前边界 |
| --- | --- |
| 01_M3_CreateTables.sql | 四表、内部主外键、两列证书唯一键、工时派单唯一键及基础约束 |
| 02_M3_CrossModuleFK.sql | 三条出向外键；需真实service_org、service_item和dispatch_record，先M3 02再M2 02复用同义外键 |
| 03_M3_Indexes.sql | 四个既定非聚集索引 |
| 04_M3_SchemaValidation.sql | 结构核对；整合时在执行窗口将@RequireCrossModuleFK设为1；原文件默认0 |
| 05_M3_TestData.sql | 分阶段数据准备；默认不写入，**当前尚未入库且需修订机构业务键/签到流程，不能直接视为可运行整合种子** |
| 06_M3_ConstraintTests-v3.sql | 正式隔离约束回归入口，59项；T036定向负例，T037/T047精确约束白名单及11字段回滚快照 |
| 07_M3_IntegrationFKTests.sql | 有合法测试批次后验证真实外键，默认关闭写入；此前SKIP不计PASS |
| 08_M3_ScheduleNoOverlap.sql | 排班AFTER INSERT/UPDATE触发器；未取消班次不重叠，相邻允许 |
| 09_M3_ScheduleTests.sql | 指定已有合法测试护工的18项独立用例，默认不写入 |
| 10_M3_RunScheduleTests.py | 最新独立回归驱动；同目录读取06-v3，保留事务重试、资源清理和显式异常验收 |
| 11_M3_Views.sql | 资质、排班、月度有效工时3个普通视图 |
| 12_M3_ComplexQuery.sql | 护工—排班—工时三表按月汇总，仅统计审核通过且分钟明确记录；跨月归签到月 |

全新结构整合顺序：M1基础表→M3/M2基础表→M3外键→M2外键（Standalone=0）→M1外键→M3索引/08/11→严格目录核对。不要将成员2Standalone模拟表放入整合库。08须在开放排班写入前部署。M1审计脚本写死旧库名，本轮结构验收使用了独立目录查询，没有直接执行该旧库USE。

## 在仓库目录复现独立回归

需要Windows、SQL Server Express本地实例、ODBC Driver 18、pyodbc，以及Windows集成身份的建库权限。进入本目录：

```powershell
python -O 10_M3_RunScheduleTests.py
```

默认只使用正式06-v3，同连接连续两轮，再运行现有排班18项及两类各3轮并发、低权限检查。可使用--schedule-only只测排班，此时59项必须标为NOT_RERUN。驱动从本目录读取脚本；历史证据路径为[evidence/key-results/排班测试原始结果-v1.json](evidence/key-results/排班测试原始结果-v1.json)。自动建立唯一命名专用库，保留数据库、不复用或删除已有库；合成夹具仅用于独立业务规则，不伪造成员1/2正式数据。成功或异常均清理本轮事务、连接、用户和夹具；无法清理将标FAILED并记录原因。

运行结果会生成唯一命名schedule_execution_*.json，请审阅后另行保存，不将每次运行产生的日志自动纳入提交。死锁1205只允许有限次数整笔重试；51201是业务冲突，不再重试。历史发生过一次1205，不宣称零死锁。

## 证据与结果

- [历史死锁原始结果](evidence/key-results/排班测试原始结果-v1.json)
- [历史56/3失败](evidence/key-results/schedule_execution_Codex_M3_Schedule_20261119_140416_349105.json)
- [06-v3及排班/并发完整成功](evidence/key-results/schedule_execution_Codex_M3_Schedule_20261119_142208_946966.json)
- [资源异常检查摘要](evidence/key-results/resource_failure_results.json)
- [三方零数据结构目录结果](evidence/key-results/全库结构联调原始结果-v1.json)
- [基础结构联调报告](../docs/全库结构联调测试报告-v1.md)
- [06-v3修订报告](06约束测试v3修订与完整回归报告-v1.md)
- [视图及查询说明](视图与复杂查询设计及测试说明-v1.md)

原06与v2仅归档在[evidence/historical-sql](evidence/historical-sql/)，供追溯，不作为当前入口。证据副本只脱敏个人路径/主机名，保留用例、错误号、约束及状态；完整未脱敏材料保留本地，不删除。

## 当前阶段与待联调

**成员1—3基础结构联调通过，05测试数据尚未入库，成员5接口及端到端派单仍待联调。** 零数据结构通过不等于20条/表数据验收、查询统计语义、业务并发或性能通过。

机构最终唯一键为(org_name,org_address)，05仍按org_code查询，需下一轮获准后修订本方脚本；工时种子要求服务中而M2 START先要求签到，须分阶段协调。成员5rectification尚缺；项目下架后是否允许历史订单派单、带派单/工时的班次更正及容量下调、工时与派单班次一致保护、正式RBAC、混合锁顺序等仍待确认或实现。所有历史报告按其阶段解释，不覆盖原失败或夸大最新结果。
