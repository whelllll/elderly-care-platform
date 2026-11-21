# 社区居家养老智慧服务平台：Python持久层

沿用 SQLAlchemy 2.0 + pyodbc + SQL Server，提供全组五个成员的数据访问、业务过程调用、登录与角色/数据范围校验。该目录是上层应用可调用的Python包，不包含HTTP服务器、页面或数据库自动迁移。

## 覆盖范围

| 模块 | 正式表/入口 |
| --- | --- |
| 成员1 | service_org、elder_profile、ability_assessment、care_plan、care_plan_item；档案总览过程 |
| 成员2 | service_item、service_order、dispatch_record；创建订单、派单、改派、接单、撤回、取消、开始、完成及围栏校验 |
| 成员3 | caregiver、caregiver_certificate、caregiver_schedule、work_record；签到、签退、工时审核 |
| 成员4 | sys_user、monitor_device、vital_sign、emergency_event；设备/体征、应急登记、接单与闭环；账号管理 |
| 成员5 | subsidy_policy、subsidy_application、subsidy_application_item、subsidy_audit_log、quality_inspection、rectification；申报、明细汇总、三级审核、拨付、整改创建/提交/复查 |

22个模型继承`DeferredReflection`，启动时读取**已经部署的正式表**。字段、IDENTITY、默认值、CHECK、外键和计算列以数据库为准；代码不调用`create_all`、不建模拟表、不修改各成员SQL。数据库DDL改变后应重启应用并重新初始化模型。

所有模型关闭`implicit_returning`，兼容SQL Server已有AFTER触发器；数据库负责生成主键和计算列，不手工指定IDENTITY。

## 安装与数据库配置

要求Python 3.11+、SQL Server及ODBC Driver 18。从仓库根目录运行：

```powershell
python -m pip install -r persistence_python/requirements.txt
$env:ELDERCARE_DATABASE_URL = 'mssql+pyodbc://localhost/ElderCareTest?driver=ODBC+Driver+18+for+SQL+Server&TrustServerCertificate=yes'
```

将`ElderCareTest`替换为实际用户数据库，实例名、加密和认证参数按本机配置填写。示例未包含用户名/密码，使用Windows集成认证；SQL登录的凭据只放环境变量，不提交到Git。缺少配置时不会默认连接`master`，明确禁止master/tempdb/model/msdb。

先按组内顺序部署22张正式表及外键、成员3排班触发器、成员1总览视图/过程、成员2的06/05、成员4的02、成员5的05/06。账号由成员4的09/10/12维护；仅在测试库使用演示密码。

## 会话、登录和数据范围示例

```python
from getpass import getpass
from persistence_python.db import configure
from persistence_python.member1_dao import Member1DAO
from persistence_python.security import LoginService, SessionStore

db = configure()  # 验证业务库并反射正式表；不建表。

# 单位名称来自真实后端配置，不能接收客户端任意提交的值。
organizations = {"comm_admin": "实际社区审核单位", "street_sup": "实际街道审核单位",
                 "civil_sup": "实际民政监管单位"}
tokens = SessionStore(LoginService(db, organization_names=organizations))
token = tokens.login("comm_admin", getpass("密码："))
with db.session() as session:
    actor = tokens.resolve(session, token)  # 每次重新校验账号状态、角色和身份绑定。
    elders = Member1DAO().elders.page(session, actor, page=1, size=20)
tokens.logout(token)
db.close()
```

方案A：社区、街道、民政不配置、不执行社区/街道/区县精确过滤；仍须通过每项操作的角色权限及相关任务校验。`DataScope`和旧`scopes`参数仅保留接口兼容，不提供行政隔离保证。社区管理员保留建档、评估、计划、代下单、派单、社区初审等权限。

老人/家属查询核对真实`sys_user.elder_id`与服务端身份快照；护理员的订单和派单按本人`caregiver_id`过滤，不能因服务过同一老人而读取其他护工的订单。机构负责人按`org_id`过滤护工、派单和相应订单。缺少必要身份绑定时拒绝访问。街道/民政普通业务不能任意修改；街道允许复审及整改复查，民政允许终审及质量抽查，保留成员4矩阵明确的拨付权限。未找到政策维护的明确授权，因此不向民政账号开放通用政策写权限。

`Principal`只能由后端认证代码构造，不能从请求中的角色、用户ID或范围直接反序列化。系统管理员按成员4约定拥有业务只读权限及账号管理权限，不默认拥有派单权限。

`SessionStore`适合课程演示的单进程应用：随机令牌仅保存摘要，30分钟空闲或8小时绝对期限任一达到即失效。每次请求刷新数据库账号状态、角色与五项身份字段；密码修改后原令牌失效，注销立即失效。多进程部署需要接入共享Session实现。

`security/http.py`提供可挂接现有WSGI应用的`AuthenticationMiddleware`，未登录/失效返回401，未授权返回403，并提供当前请求的`environ['eldercare.actor']`和`environ['eldercare.session']`。适配器在事务成功提交后发送业务响应；业务层必须使用该服务端身份调用DAO。当前仓库没有现成HTTP应用/路由，因此本轮仅完成适配器协议测试，未声称已接入真实服务。

## CRUD和业务调用约定

`Member1DAO`至`Member5DAO`暴露各模块表DAO，可用`get/required/page/get_all/add/update/delete/batch_add/batch_update`；查询和写入都必须传`actor`。`page(..., filters={'字段': 值})`提供参数化等值筛选，字段与排序均使用白名单；分页每页1至200条。`batch_add`支持列表和生成器；`batch_update`接收`[(主键, {'字段': 新值}), ...]`，先检查所有记录、字段与数据范围，再统一写入。`get_all`仍检查范围，但导出规模由上层限制。

订单、派单、工时、应急事件、补贴申报/明细/审核日志、质量抽查、整改及账号等受控表禁止通过通用DAO直接写入，使用对应模块的业务方法。主键、计算列及未知字段不能通过通用DAO赋值。上层不要暴露原始SQL会话或模型给不可信请求，也不要直接序列化含密码哈希的`SysUser`。

```python
from persistence_python.member2_dao import Member2DAO

with db.session() as session:
    actor = tokens.resolve(session, token)
    order_id = Member2DAO().create_order(
        session, actor, elder_id=actual_elder_id, service_id=actual_service_id,
        appointment_time=appointment, service_address="阳光社区-实际服务地址")
    dispatch_id = Member2DAO().action(
        session, actor, order_id, "DISPATCH", caregiver_id=actual_caregiver_id)
```

示例的ID、时间和地址由调用方按实际业务数据提供。成员2状态流转使用正式`usp_M2_*`过程，保留成员5共同锁、限制视图、容量及冲突检查，不用ORM直接改状态。护理员通过自身账号执行接单/签到/开始/签退；机构负责人审核工时；完成订单仍需实际取得确认并提供服务记录。

成员5整改创建/复查调用正式过程。提交整改在共同机构→护工锁内设置提交时间和待复查状态，不直接设置限制标志；提交/复查都在锁内重新读取状态，限制标志由正式触发器维护。补贴申报创建和汇总复用正式过程；明细、审核日志与申报头在同一事务写入。

成员3签到要求“订单待服务＋派单已接单”，签退要求已START进入服务中。成员2`order_details/blocked_scope`和成员5`application_progress/subsidy_trace`读取正式视图并保留数据范围检查；限制展示结果不能替代派单过程内的实时加锁检查。

## 成员5任务分配：当前阻塞项

正式外键将`subsidy_audit_log.auditor_id`、`quality_inspection.inspector_id`、`rectification.reviewer_id`关联到`sys_user.user_id`，这些字段记录实际操作人。`usp_M5_ReviewRectification`在复查时写入`reviewer_id`，并非先验任务分配。`current_auditor_id`也未找到明确的预分配契约。

因此默认`Member5DAO()`在补贴审核、质量抽查、整改创建/复查入口抛出`AssignmentUnavailable`（403）。这会阻止目前无法验证归属的操作，**不表示真实任务分配已经实现**。需要成员5确认已有正式表/字段和各阶段分配规则，再实现服务端`task_policy.require_assigned(session, actor, operation, target_id)`并注入。该实现必须查询真实数据库，在同一工作单元内保护分配校验；不能由请求选择策略，也不能用“允许所有人”的策略上线。

操作人统一取服务端`Principal.user_id`，审核单位取`LoginService(..., organization_names={username: 单位名称})`配置，不接受冒填操作人，不以用户名替代单位名。测试中的`TestOnlyAssignmentPolicy`仅用于运行真实SQL业务流程，不证明真实任务归属安全。

## B3的28账号凭据

本项目未提供实际B3账号清单、目标库及密码来源，本轮没有重置实际B3账号。已补充`security/accounts.py`用于核验/显式迁移已有28账号，不创建账号，不修改角色和身份绑定。

在安全配置目录维护JSON清单，恰好28个不同的真实用户名：

```json
{"accounts": [{"username": "实际用户名", "password_env": "该账号密码对应的环境变量名"}]}
```

上例仅示意一条结构，不能直接充当28账号清单；文件不写明文密码。默认命令只核验：

```powershell
python -B -m persistence_python.security.accounts --manifest C:/secure-config/b3-accounts.json
# 确认目标库和28账号，设置管理员及每个账号的密码环境变量后，才显式迁移：
python -B -m persistence_python.security.accounts --manifest C:/secure-config/b3-accounts.json --apply --admin 实际系统管理员账号
```

维护管理员密码从`B3_ADMIN_PASSWORD`读取；28个密码各从清单的环境变量名读取，不打印凭据。所有账号验证完整后才更新，在一个事务中写入；每人随机16字节盐、独立哈希，拒绝演示密码`Admin@123`。应用部署B3时设置`ELDERCARE_PROFILE=B3`和`ELDERCARE_B3_ACCOUNT_MANIFEST`，初始化将拒绝共享/演示盐或哈希、缺失账号和非28账号清单。只有显式维护入口可暂缓启动核验以便迁移；普通启动不能跳过。

环境变量示例见[.env.example](.env.example)，文件不会自动加载，需要现有后端配置或PowerShell设置变量。

**事务边界**：`db.session()`正常退出提交，异常退出回滚并关闭。DAO只flush，不commit。过程包装器与ORM共用同一DBAPI连接，显式确保SQL事务已开始，避免过程误判为自有事务并提前提交。参数全部绑定；过程名、参数名和输出类型来自白名单；处理多结果集和OUTPUT参数。存储过程异常会使整个工作单元回滚，调用方不得捕获后继续使用该工作单元，应该在外层捕获并开启新会话。

`security`的登录失败计数使用独立工作单元并在错误抛出前提交：连续失败5次锁定30分钟；锁定中即使正确密码也拒绝、不延长截止时间；到期先解锁、清零再验证本次密码；停用不自动解除。密码口径兼容成员4的Base64盐、PBKDF2-HMAC-SHA256/100000轮，新账号、本人改密和管理员重置均生成独立随机16字节盐。账号状态变更由系统管理员入口完成。

## 测试

```powershell
# 未配置测试库时，真实数据库用例会明确跳过，不会连接业务库。
python -B -m pytest persistence_python -q -p no:cacheprovider

# 真实测试必须指定专用库，名称以Codex_Persistence_开头，且已部署全组正式SQL。
$env:ELDERCARE_TEST_DATABASE_URL = 'mssql+pyodbc://localhost/Codex_Persistence_YourTest?driver=ODBC+Driver+18+for+SQL+Server&TrustServerCertificate=yes'
python -B -m pytest persistence_python -q -p no:cacheprovider
```

测试使用唯一标记构造夹具，业务夹具在测试后回滚；登录和提交测试只清理自己创建的临时账号/项目，不删除数据库。IDENTITY编号可能出现空号。测试不使用SQLite冒充SQL Server，也不修改成员SQL。

本轮测试范围、实际结果、未完成验收项及逐项需求对应关系见[验收对照与修改报告.md](验收对照与修改报告.md)。双连接测试使用不同`@@SPID`，在服务端观察真实锁等待后分别验证提交和回滚；不是高并发压力测试。B3测试使用新建的隔离28账号，不代表实际B3账号已迁移。涉及成员5业务流程的部分用例显式注入测试策略，不将其记作真实任务分配校验通过。
