# 成员1：老人档案与能力评估模块

社区居家养老智慧服务平台数据库课程设计。

本模块由成员1负责，包含4张业务表和1张公共基础表，共 **5张表、39个字段**，统一使用 SQL Server 和 `dbo` 架构。

## 一、负责的数据表

| 数据表 | 主要用途 | 字段数 |
|---|---|---:|
| `elder_profile` | 保存老人基本档案、身份信息、居住社区及档案状态 | 12 |
| `ability_assessment` | 保存老人能力评估历史、量表、得分及有效期 | 8 |
| `care_plan` | 保存老人照护计划、服务频次、计划日期及责任护工 | 8 |
| `care_plan_item` | 保存照护计划与服务项目之间的关联明细 | 3 |
| `service_org` | 保存公共服务机构信息，供其他模块通过 `org_id` 关联 | 8 |
| **合计** | **5张表** | **39** |

其中，`service_org` 为成员1负责设计和维护的公共机构表。成员3的 `caregiver.org_id` 已在其 v4 数据字典中调整为 `INT NOT NULL`，引用 `service_org.org_id`。

## 二、文件清单

| 文件 | 内容 |
|---|---|
| `01_member1_tables.sql` | 创建成员1负责的5张表、模块内外键、约束及索引 |
| `02_member1_cross_module_foreign_keys.sql` | 添加成员1表指向成员2、成员3表的跨模块外键 |
| `03_member1_test_data.sql` | 插入机构、老人档案、能力评估和照护计划测试数据 |
| `04_member1_views.sql` | 创建并查询3个视图 |
| `05_member1_complex_query.sql` | 老人能力评估与照护计划跟进情况综合查询 |
| `06_member1_stored_procedure.sql` | 创建并测试老人照护信息查询存储过程 |
| `07_member1_structure_audit.sql` | 检查表、字段、主键、外键、约束和索引 |
| `成员1_最终设计数据字典.docx` | 成员1数据表字段、类型及约束说明 |
| `README.md` | 本模块说明及脚本执行方法 |

局部 E-R 图将整理后另行补充，当前文件夹中的 SQL 和数据字典可先进行阶段性提交。

## 三、独立测试环境

独立测试数据库：`Member1_Standalone_Test`

### 1. 创建数据库

在 SSMS 中执行：

```sql
CREATE DATABASE Member1_Standalone_Test;
```

创建完成后，将查询窗口的当前数据库切换为 `Member1_Standalone_Test`。

### 2. 执行脚本

独立测试阶段按以下顺序执行：

1. `01_member1_tables.sql`
2. `03_member1_test_data.sql`
3. `04_member1_views.sql`
4. `05_member1_complex_query.sql`
5. `06_member1_stored_procedure.sql`
6. `07_member1_structure_audit.sql`

说明：

- `01` 创建五张表及模块内关系。
- `03` 插入测试数据。
- `04` 创建三个视图并查询视图结果。
- `05` 执行老人评估与照护计划综合查询。
- `06` 创建并执行存储过程。
- `07` 检查数据库结构。
- 独立测试库没有成员2的 `service_item` 和成员3的 `caregiver` 表，因此暂不执行 `02_member1_cross_module_foreign_keys.sql`。

### 3. 测试数据情况

`03_member1_test_data.sql` 中包含以下虚构测试数据：

| 数据表 | 测试记录数 |
|---|---:|
| `service_org` | 5 |
| `elder_profile` | 20 |
| `ability_assessment` | 30 |
| `care_plan` | 20 |
| `care_plan_item` | 0 |

`care_plan_item` 暂未插入记录，因为其中的 `service_id` 需要关联成员2 `service_item` 表中的实际服务项目编号，待小组整合测试时补充。

测试数据脚本采用防重复插入处理，可在同一测试库中重复执行。

## 四、视图、复杂查询与存储过程

### 1. 三个视图

`04_member1_views.sql` 创建以下视图：

- `vw_elder_latest_assessment`：查询每位老人的最新一次能力评估及评估有效期。
- `vw_elder_care_plan_summary`：统计每位老人的照护计划总数及不同状态的计划数量。
- `vw_active_care_plan`：查询当前处于生效状态且在有效日期范围内的照护计划。

脚本末尾包含视图创建检查和视图查询语句。

### 2. 复杂 SQL 查询

`05_member1_complex_query.sql` 综合老人档案、最新能力评估和照护计划，形成老人照护跟进情况清单。

查询使用多表连接、CTE、`ROW_NUMBER()` 窗口函数、分组统计和 `CASE WHEN` 判断，给出评估状态、计划数量及照护跟进建议。

### 3. 存储过程

`06_member1_stored_procedure.sql` 创建存储过程：

`dbo.usp_GetElderCareOverview`

输入参数：

- `@elder_id INT`：老人编号。

功能：根据老人编号查询老人基本档案、最新能力评估、评估有效期、照护计划统计和照护计划明细。脚本包含正常编号及不存在编号的测试方式。

## 五、跨模块接口

跨模块外键需在成员2、成员3相关数据表部署完成后，在小组整合数据库中执行和验证。

| 所在模块 | 外键字段 | 引用表及字段 | 当前情况 |
|---|---|---|---|
| 成员1 `care_plan` | `responsible_caregiver_id INT NULL` | 成员3 `caregiver(caregiver_id)` | 字段接口已确定，待整合库验证 |
| 成员1 `care_plan_item` | `service_id INT NOT NULL` | 成员2 `service_item(service_id)` | 字段接口已确定，待整合库验证 |
| 成员3 `caregiver` | `org_id INT NOT NULL` | 成员1 `service_org(org_id)` | 成员3 v4 数据字典已确认，实际部署待整合验证 |
| 成员2 `service_order` | `elder_id INT NOT NULL` | 成员1 `elder_profile(elder_id)` | 成员2数据字典已列出该关联，最终以整合DDL为准 |

跨模块接口说明：

1. `service_org.org_id` 为成员1公共机构表主键。
2. 成员3 v4 已将 `caregiver.organization_name` 调整为 `caregiver.org_id INT NOT NULL`；成员3已反馈其跨模块外键脚本配置了对 `service_org.org_id` 的引用，实际执行结果待整合库验证。
3. `02_member1_cross_module_foreign_keys.sql` 负责添加成员1照护计划到成员3护工表、照护计划服务明细到成员2服务项目表的外键。
4. 成员1的跨模块外键脚本及成员3反馈的 `caregiver.org_id` 机构关联均采用 `ON DELETE NO ACTION`；其他模块的删除规则以各自最终DDL为准。实际执行前应确认被引用表、字段类型及数据均已准备好。
5. 当前独立测试库的跨模块外键尚未完成联调，不将其标记为已通过。

## 六、结构设计与验收情况

成员1独立测试库已完成建表、测试数据插入及独立运行检查。

目前已检查：

- 5张表及字段数量：`service_org` 8列、`elder_profile` 12列、`ability_assessment` 8列、`care_plan` 8列、`care_plan_item` 3列。
- 主键、唯一约束及模块内外键。
- CHECK 约束和 DEFAULT 默认约束。
- 索引及索引字段。
- 三个视图的创建及查询。
- 复杂查询结果。
- `usp_GetElderCareOverview` 存储过程的创建及执行。

结构验收脚本显示五张表均存在，字段数量与设计一致，三个预期普通索引均存在。模块内外键已在独立测试库检查。

**尚未完成：** 成员1与成员2、成员3的跨模块外键在同一整合数据库中的实际联调；`care_plan_item` 使用真实服务项目编号的测试数据补充。

## 七、GitHub 提交建议

建议将本模块文件放入小组仓库的 `member1` 目录。

建议提交说明：

```text
feat(member1): 完成老人档案与能力评估模块初版设计及SQL实现
```

本次提交为成员1模块的阶段性成果。后续根据小组最终数据字典和整合测试结果更新跨模块接口及 E-R 图。
