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

方案A：社区、街道、民政不配置、不执行社区/街道/区县精确过滤；仍须通过每项操作的角色权限和业务状态校验。本轮不实现尚未确认的任务预分配。`DataScope`和旧`scopes`参数仅保留接口兼容，不提供行政隔离保证。社区管理员保留建档、评估、计划、代下单、派单、社区初审等权限。

老人/家属查询核对真实`sys_user.elder_id`与服务端身份快照；护理员的订单和派单按本人`caregiver_id`过滤，不能因服务过同一老人而读取其他护工的订单。机构负责人按`org_id`过滤护工、派单和相应订单。缺少必要身份绑定时拒绝访问。按2026-11-22确认的简化矩阵，街道仅允许街道复审和整改复查，民政仅允许质量抽查；两者保留普通业务查询及本人改密。民政终审、拨付、整改创建和政策维护不在授权内，默认拒绝403。其他六角色授权保持不变。

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

## V2.2审核待办、归属组件及指派接口

成员5在`266ae3a`确认：补贴申请`current_auditor_id`指向指定审核人的`sys_user.user_id`；NULL表示当前节点对应角色可先到先得办理，非空仅本人可办理。只有社区初审和街道复审适用；质量抽查、整改不适用预分配。日志`auditor_id`及抽查/复查操作人继续由Session提供，不能从请求冒填。

`Member5DAO.audit_todos(session, actor, page=1, size=20)`按角色对应节点、未分配/分配本人及既有数据范围过滤，按申请ID稳定分页；普通申报只读查询不受待办过滤影响。`check_audit_task(session, actor, application_id)`在现有`UPDLOCK,HOLDLOCK`申请行锁内刷新状态，调用固定的`require_audit_task`校验角色、节点和归属，不符合抛AccessDenied（现有HTTP适配器转403）。检查组件不写归属、不认领、不提交事务；返回快照不能跨事务当作审核授权凭证。

`audit()`在现有`UPDLOCK,HOLDLOCK`申请行锁内刷新状态及`current_auditor_id`，强制调用`require_audit_task`：未分配或分配给本人允许，同节点分配给其他人返回403；`task_policy=None`不能绕过。可选策略仅追加限制。节点流转通过`usp_M5_AuditAdvance`原子更新状态、清空指派并写日志，Python不自行回写`current_auditor_id`，下一节点重新办理或指派。

`assign_auditor(session, actor, application_id, assignee_id)`封装正式`usp_M5_AssignAuditor`并返回整数`assigned_to`，复用调用方事务及数据库行锁。发起人限`COMMUNITY_ADMIN`和`STREET_SUPERVISOR`，在申请行锁内分别核验“待社区初审”和“街道复审中”节点，错节点返回403。过程层继续校验被指派角色；保留重新指派及并发指派最后一次成功生效的行为。

抽查、整改复查和整改创建已移除预分配策略调用；角色、状态、数据归属、单位和共同锁检查保留。整改提交仍保持V2.1状态集合及实现，暂不切换至新`usp_M5_SubmitRectification`：Python允许“复查不通过”重提，而过程仅接受待整改/整改中/逾期未改，需成员5确认统一方案。

操作人统一取服务端`Principal.user_id`，审核单位取`LoginService(..., organization_names={username: 单位名称})`配置，不接受冒填操作人，不以用户名替代单位名。测试中的`TestOnlyAssignmentPolicy`仅用于运行真实SQL业务流程，不证明真实任务归属安全。

节点流转即清空指派已按成员5过程落实，指派发起角色已按本次要求开放；整改重新提交状态及正式提交过程的统一使用方式仍待成员5确认。三态和并发测试、20条订单参数核对及历史V2.2结果见[开发联调说明](../member2/2026-11-22_后端开发与联调说明.md)。正式20条订单仍等B1/B2验收和整合负责人授权，不占用成员5预留的3张订单。

历史V2.2独立SQL Server全量回归：**160通过、0失败、0跳过，43.26秒**（原131项和新增29项）。43个Python文件语法及`git diff --check`通过。真实双连接覆盖同节点办理提交/回滚、指派与检查互斥、并发指派最后成功者生效、机构整改与派单共同锁；完整派单三态通过。证据：`C:/Users/65770/Documents/Codex/work/m2-v22-audit-20261122/pytest-full-results.xml`。这些历史结果不包含本次归属检查接入后的端到端验收。

2026-11-23本次接口修复仅运行离线回归：共收集181项，**115通过、0失败、66跳过，2.02秒**；其中审核任务测试30通过、20跳过。SQL Server用例在执行前显式跳过，连接入口拦截统计为0次真实连接尝试；未连接或写入任何数据库。43个Python文件语法检查通过。首次离线运行有1项旧街道权限矩阵预期失败，按本次开放指派权限更新后最终全部离线用例通过。最终报告：`C:/Users/65770/Documents/Codex/work/m2-m5-interface-20261123-fix/pytest-offline-final.xml`。原131项中的数据库测试及本次新增真实归属/流转测试未重跑，不将历史通过记录计为本次通过。

## B3的28账号凭据

成员4的`13_b3_accounts_28.sql`已随main `d4e174f`合并，提供动态身份选择及28组固定凭据；它替代10/12，仅适用于空sys_user。逐组算法兼容性已通过，统一公开演示密码仍须安全迁移。目标库已确认，实际清单仍待核对，本轮没有重置实际B3账号。`security/accounts.py`核验/显式迁移已有28账号，不创建账号，不修改角色和身份绑定。

**最新确认：凭据方案及正式目标数据库均已确认。** 保留13脚本及现有28账号名单、角色和身份绑定；成员2通过Python工具为每个账号初始化独立安全密码及新的16字节随机盐，保持PBKDF2-HMAC-SHA256/100000/Base64。

| 项目 | 已确认信息 |
| --- | --- |
| SQL Server实例 | `LAPTOP-5SQMJQQD\SQLEXPRESS` |
| 正式联调数据库 | `Codex_M1M5_Data_20261121_071555_de0517` |
| V2提交 | 已提交main，commit SHA：`207868f` |
| 正式数据写入授权 | 待完成，须取得整合负责人明确授权 |
| 实际28账号安全凭据初始化 | 待完成 |
| 实际28账号登录及Session身份验收 | 待完成 |

正式Data库未经整合负责人授权不得写入；目标确认不代表已获得写入授权。本轮仅开展代码完善、独立测试及文档更新，不连接或写入正式Data库。实际28账号清单核对、安全凭据准备、正式初始化和登录验收仍待完成。

在安全配置目录维护JSON清单，恰好28个不同的真实用户名：

```json
{"accounts": [{"username": "实际用户名", "password_env": "该账号密码对应的环境变量名"}]}
```

上例仅示意一条结构，不能直接充当28账号清单；文件不写明文密码。默认命令只核验：

```powershell
python -B -m persistence_python.security.accounts --manifest C:/secure-config/b3-accounts.json
# 后续取得整合负责人写入授权、核对28账号并准备安全配置后才可迁移；本轮不执行：
python -B -m persistence_python.security.accounts --manifest C:/secure-config/b3-accounts.json --apply --admin 实际系统管理员账号 --expected-database 已确认数据库名
```

维护管理员密码从`B3_ADMIN_PASSWORD`读取；28个密码各从清单的独立环境变量读取，不打印凭据。所有参数和账号验证完整后才更新，在一个事务中写入；每人随机16字节盐、独立哈希，拒绝公开演示密码及任意两个账号共享同一新密码。应用部署B3时设置`ELDERCARE_PROFILE=B3`和`ELDERCARE_B3_ACCOUNT_MANIFEST`，初始化将拒绝共享/演示盐或哈希、任何仍对应公开演示密码的凭据、缺失账号和非28账号清单。只有显式维护入口可暂缓启动核验以便迁移；普通启动不能跳过。安全初始化后，执行`python -B -m persistence_python.security.verify_b3 --manifest C:/secure-config/b3-accounts.json --expected-database 已确认数据库名`验证真实28账号登录和Session。

完整无密码模板见[security/b3-accounts.template.json](security/b3-accounts.template.json)：共28项，模板中实际ID留null、动态用户名为占位符，**必须在仓库外复制并填写真实查询结果，不能直接执行**。更新和登录验收都要求人工核对的`expected`五项身份；更新前在行锁内比对，任何不符均不修改凭据。清单拒绝明文密码字段、未知字段、重复用户名、重复环境变量名及与`B3_ADMIN_PASSWORD`冲突；变量名按大小写不敏感检查，适配Windows。普通只读凭据审计为兼容旧清单仍允许省略expected，不能代替完整身份验收。

### 正式目标已确认，取得整合负责人授权后的操作顺序

1. 取得整合负责人对正式Data库写入及登录验收的明确授权，核对上述实例、数据库名、允许维护的28个账号及维护窗口；暂停登录请求，避免管理员自更新及并发改密影响验证。核对13是否已执行；仅在sys_user为空且依赖满足时按成员4流程执行13，已有账号不重跑、不清表、不叠加10/12。
2. 从该库查询实际username、user_id、role_code、org_id、elder_id、caregiver_id，人工核对后填入仓库外清单。角色分布为20护工、2机构负责人、其余6种角色各1，老人和家属绑定同一老人。
3. 在受控密码管理器为各账号生成并保存独立高熵密码，建议至少24随机字节经安全编码；工具保留既有至少8字符校验，但不把人工凑够8字符当推荐生成方式。通过受控进程环境注入28个密码和当前维护管理员密码；不把密码写入清单、.env、SQL、命令历史、截图、Git或日志。各账号仅向对应持有人通过受控私密渠道分发，管理员凭据单独保管。
4. 先执行离线预检（不创建数据库连接）：`python -B -m persistence_python.security.accounts --manifest C:/secure-config/b3-accounts.json --check-config`。该检查只验证配置格式和密码独立性，不证明目标数据库或实际账号已就绪。
5. 设置`ELDERCARE_DATABASE_URL`到已确认目标库，执行上面的`--apply --admin ... --expected-database ...`。工具先校验全部配置，再核对实际`DB_NAME()`，管理员登录后在一个事务中锁定28行、核对expected，仅更新password_hash/password_salt/pwd_update_time/updated_at；不更改角色、身份、账号状态、失败计数、锁定时间或其他业务关联。管理员正常登录本身会更新last_login_time并清零其失败计数。凭据错误的管理员登录仍按原锁定规则处理，不自动重试。
6. 开启B3正常启动门禁，再运行上面的`verify_b3`命令。验收先检查配置、凭据、角色和绑定，再只读验证全部密码；所有账号就绪后才逐一登录、解析Session并核对user_id/username/role_code/org_id/elder_id/caregiver_id及失败计数清零。停用或锁定账号不会被工具自动启用；先按既有授权流程处理。成功登录有正常审计更新，验收不是完全只读操作。验证期间若账号被并发变更，仍可能失败，应重新核对后再执行，不绕过锁定规则。
7. 保存不含密码、哈希、盐或令牌的统计结果、目标库及版本证据；结束后移除临时进程环境变量，关闭维护进程。正式密码仅保留在受控密码管理器中。确认验收结果后恢复业务；若失败，记录真实结果，不把隔离测试当正式验收。再次执行apply会轮换盐并使旧Session失效，应作为显式维护，不盲目重跑。

本轮独立SQL Server全量回归：**131通过、0失败、0跳过，40.65秒**。包括28个隔离账号凭据更新及身份/状态字段保持、共享新密码拒绝、离线配置和目标库预检、28隔离账号登录/角色/Session核验。证据保存在`C:/Users/65770/Documents/Codex/work/m2-b3-init-20261122-confirmed/pytest-final-results.xml`。正式目标库已确认；实际B3初始化和28账号验收仍待整合负责人授权、实际清单核对和安全凭据准备。本轮未执行正式库写入。

20条专用订单的只读预检、创建/派单/接单批次命令、清单格式、B1/B2门槛及权限矩阵，见[本次开发与联调说明](../member2/2026-11-22_后端开发与联调说明.md)。工具为`python -B -m persistence_python.order_batch`，默认不写订单，正式执行需`--execute --b1-b2-accepted`。已有批次拒绝重跑，异常整批回滚；不绕开任何数据库过程校验。

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
