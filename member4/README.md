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
| `10_sys_user_test_data.sql` | 5 个测试账号，`user_id` 1–5 |
| `11_sys_user_caregiver_fk.sql` | 成员3 `caregiver` 就绪后补外键 |
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
2. 成员3 的 `caregiver` 表在 `feature/member3-stage2-integration` 分支，合并 main 后 `09_sys_user.sql` 会自动补 `caregiver_id` 外键；未合并时先建表，后续执行 `11`。

### 执行

1. `member4/09_sys_user.sql`
2. `member4/10_sys_user_test_data.sql`
3. `member4/01_schema.sql`
4. `member4/02_views_procedures.sql`
5. `member4/04_test_data.sql`
6. `member4/03_queries.sql`
7. 成员3 分支合并 main、`caregiver` 就绪后：`member4/11_sys_user_caregiver_fk.sql`

> `01_schema.sql` 开头会检查 `dbo.sys_user`；所以必须先执行 `09`。
> `04_test_data.sql` 需要 `sys_user` 的 `user_id` 1–5；由 `10` 提供。

## 3. 账号与角色

- 登录账号：`sys_user`。
- 一人一角色：`sys_user.role_code`。
- 8 个角色：`COMMUNITY_ADMIN`、`ELDER`、`FAMILY`、`CAREGIVER`、`ORG_MANAGER`、`STREET_SUPERVISOR`、`CIVIL_SUPERVISOR`、`SYS_ADMIN`。
- 权限不落库，服务层按 `role_code` 判断；数据范围按本人/本社区/本机构/本辖区过滤。

测试账号（密码统一 `Admin@123`）：

| user_id | username | 角色 |
|---:|---|---|
| 1 | `admin` | `SYS_ADMIN` |
| 2 | `comm_admin` | `COMMUNITY_ADMIN` |
| 3 | `street_sup` | `STREET_SUPERVISOR` |
| 4 | `civil_sup` | `CIVIL_SUPERVISOR` |
| 5 | `org_mgr` | `ORG_MANAGER` |

## 4. 说明

- `elder_profile` 是成员1 的表，M4 只外键引用，不重复建表。
- `caregiver` 是成员3 的表；`sys_user.caregiver_id` 的外键在成员3 分支合并 main 后补。
- `service_org` 目前由成员1 维护，主要是养老服务机构；街道/民政账号暂不强制 `org_id`。
- 如果以后要“一人多角色”，再增加 `sys_user_role` 关联表，当前保持一人一角色。

## 5. 验证状态

- 静态检查：M4 3 表 32 字段、5 条外键、7 条显式索引；`sys_user` 18 字段、8 角色。
- SQL 需在测试库按上述顺序执行；仓库未附执行截图。
- 测试数据脚本假设 `service_org` 有 1、2 号机构、`elder_profile` 有 1–20 号老人。
