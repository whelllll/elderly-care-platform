# 社区居家养老智慧服务平台 · 成员4

## 健康监测与应急响应（M4）+ 公共账号表 sys_user

> **M4：3 张表 / 32 个字段 / 5 条外键 / 3 个视图 / 3 个存储过程 / 5 条复杂查询 / 每表 20 条测试数据**
>
> **公共表：`sys_user` 18 个字段 / 8 个角色 / 一人一角色**

本目录是成员4 负责的 **4.4 健康监测与应急响应（M4）**，并维护公共共享表 **`sys_user`（公共用户账号及人员身份）**。

## 1. 表与文件

### M4 三张表

| 表 | 中文名 | 字段数 | 主键 |
|---|---|---:|---|
| `monitor_device` | 监测设备表 | 10 | `device_id` |
| `vital_sign` | 体征数据表 | 9 | `vital_id` |
| `emergency_event` | 应急事件表 | 13 | `event_id` |

### 公共账号表

| 表 | 中文名 | 字段数 | 说明 |
|---|---|---:|---|
| `sys_user` | 公共用户账号及人员身份 | 18 | 8 个角色，一人一角色 |

`sys_user` 说明见 [09-公共账号与人员身份.md](09-公共账号与人员身份.md)。

### 文件清单（全部在 `member4/` 平铺）

| 文件 | 内容 |
|---|---|
| `09_sys_user.sql` | `sys_user` 建表、约束、索引 |
| `10_sys_user_test_data.sql` | 5 个基础测试账号，按 `username` 判重 |
| `11_sys_user_caregiver_fk.sql` | `caregiver` 就绪但 `09` 未加外键时补 |
| `12_sys_user_business_accounts.sql` | 护工/老人/家属/机构/审核补充账号，业务键关联 |
| `01_schema.sql` | M4 三张表 + 索引 |
| `02_views_procedures.sql` | 3 个视图 + 3 个存储过程 |
| `03_queries.sql` | 5 条复杂查询 |
| `04_test_data.sql` | 三表各 20 条测试数据 |
| `01-ER图.md` | 局部 E-R 图与联系说明 |
| `02-数据字典.md` | 三表 32 字段、约束、索引 |
| `03-逻辑设计.md` | 关系模式、键、函数依赖、3NF/BCNF |
| `04-物理结构设计.md` | 存储、索引、压缩、归档 |
| `05-建表与索引.md` | M4 DDL 与索引 SQL |
| `06-视图与存储过程.md` | 视图/存储过程说明与 SQL |
| `07-复杂查询.md` | 5 条查询说明与 SQL |
| `08-测试数据.md` | 每表 20 条测试数据与验证 |
| `m4-er.png` | M4 局部 E-R 图 |

## 2. 执行顺序

### 前置条件

1. 成员1 已执行 `member1/01_member1_tables.sql` 和 `member1/03_member1_test_data.sql`，即有 `service_org`、`elder_profile`。
2. 成员3 的 `caregiver` 表已合并 main；`09_sys_user.sql` 会自动补 `caregiver_id` 外键。

### 执行

1. 成员3：`member3/sql/01_M3_CreateTables.sql`（`caregiver`，已合并 main）
2. `member4/09_sys_user.sql`
3. `member4/10_sys_user_test_data.sql`
4. `member4/12_sys_user_business_accounts.sql`（需要成员1/3 测试数据）
5. `member4/01_schema.sql`
6. `member4/02_views_procedures.sql`
7. `member4/04_test_data.sql`
8. `member4/03_queries.sql`
9. 如果 `09` 执行时 `caregiver` 还不存在：`member4/11_sys_user_caregiver_fk.sql`

> 命令行执行统一加 `-I`：`sys_user` 有筛选唯一索引，`QUOTED_IDENTIFIER OFF` 会报 Msg 1934。
>
> `01_schema.sql` 开头会检查 `dbo.sys_user`；所以必须先执行 `09`。
> `04_test_data.sql` 需要 `sys_user` 的 `comm_admin`、`org_mgr` 和 `caregiver_%` 账号；由 `10`、`12` 提供。

## 3. 账号与角色

- 登录账号：`sys_user`。
- 一人一角色：`sys_user.role_code`。
- 8 个角色：`COMMUNITY_ADMIN`、`ELDER`、`FAMILY`、`CAREGIVER`、`ORG_MANAGER`、`STREET_SUPERVISOR`、`CIVIL_SUPERVISOR`、`SYS_ADMIN`。
- 权限不落库，服务层按 `role_code` 判断；数据范围采用方案 A：只按 `elder_id` / `caregiver_id` / `org_id` 过滤，不做行政区域级隔离。

测试账号（密码统一 `Admin@123`）：

| username | 角色 |
|---|---|
| `admin` | `SYS_ADMIN` |
| `comm_admin` | `COMMUNITY_ADMIN` |
| `street_sup` | `STREET_SUPERVISOR` |
| `civil_sup` | `CIVIL_SUPERVISOR` |
| `org_mgr` | `ORG_MANAGER` |

`user_id` 由 IDENTITY 自动生成，不写死。

补充业务账号由 `12_sys_user_business_accounts.sql` 生成，主测试场景约 37 个：

| 类型 | 最多 | 关联方式 |
|---|---:|---|
| 护理员 | 全部在岗（主场景 20） | `caregiver` 实际在岗记录 |
| 老人 | 5 | `elder_profile.id_card_no` |
| 家属 | 5 | 同上 |
| 机构负责人 | 3 | `service_org(org_name, org_address)` |
| 社区审核 | 2 | 第 2、3 家正常机构 |
| 街道/民政审核 | 2 | 不绑机构 |

`12` 不写死 `elder_id`、`caregiver_id`、`org_id`。

## 4. 说明

- `elder_profile` 是成员1 的表，M4 只外键引用，不重复建表。
- `caregiver` 是成员3 的表，已合并 main；`09` 建表时自动补 `caregiver_id` 外键，`11` 只作兜底。
- `service_org` 目前由成员1 维护，主要是养老服务机构；街道/民政账号暂不强制 `org_id`。
- 如果以后要“一人多角色”，再增加 `sys_user_role` 关联表，当前保持一人一角色。

## 5. 验证状态

- 静态检查：M4 3 表 32 字段、5 条外键、7 条显式索引；`sys_user` 18 字段、8 角色。
- SQL 需在测试库按上述顺序执行；仓库未附执行截图。
- `10` 通过成员1 测试机构名（阳光社区 / 幸福居家）查 `org_id`，不写死机构 ID。
