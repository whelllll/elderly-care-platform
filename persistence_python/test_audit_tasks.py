"""审核入口归属与指派权限测试；真实SQL测试仅在显式配置的隔离库运行。"""
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from datetime import timedelta
from threading import Event
from time import monotonic
from types import SimpleNamespace

import pyodbc
import pytest
from sqlalchemy import delete, select, text

from .base_dao import BaseDAO
from .errors import AccessDenied
from .member2_dao import Member2DAO
from .member5_dao import Member5DAO
from .models import (SubsidyApplication, SubsidyPolicy, SubsidyAuditLog, SysUser,
                     QualityInspection, Rectification, DispatchRecord, ServiceOrder,
                     CaregiverCertificate, CaregiverSchedule, Caregiver, ElderProfile, ServiceOrg, ServiceItem)
from .permissions import Principal
from .permissions.roles import ROLES
from .permissions.tasks import require_audit_task
from .procedures import call_procedure


def test_submit_rectification_uses_sql_contract_and_returns_status(monkeypatch):
    from . import member5_dao

    actor = Principal(101, "isolated", "ORG_MANAGER", org_id=301)
    calls = []
    monkeypatch.setattr(Member5DAO, "_lock_rectification", lambda *_: calls.append("lock"))

    def procedure(session, name, **values):
        calls.append((name, values))
        return SimpleNamespace(outputs={"rectify_status": "待复查"})

    monkeypatch.setattr(member5_dao, "call_procedure", procedure)
    result = Member5DAO().submit_rectification(object(), actor, 42, submit_note="补充佐证")

    assert result == "待复查"
    assert calls == ["lock", ("usp_M5_SubmitRectification", {"rectify_id": 42, "submit_note": "补充佐证"})]


@pytest.mark.parametrize("role,stage", [("COMMUNITY_ADMIN", "待社区初审"), ("STREET_SUPERVISOR", "街道复审中")])
@pytest.mark.parametrize("owner,allowed", [(None, True), (101, True), (102, False)])
def test_independent_role_stage_and_owner_check(role, stage, owner, allowed):
    actor = Principal(101, "isolated", role, org_id=301)
    application = SimpleNamespace(audit_status=stage, current_auditor_id=owner)
    if allowed:
        require_audit_task(actor, application)
    else:
        with pytest.raises(AccessDenied) as exc:
            require_audit_task(actor, application)
        assert exc.value.status_code == 403
    application.audit_status = "民政终审中"
    with pytest.raises(AccessDenied):
        require_audit_task(actor, application)


@pytest.mark.parametrize("role", sorted(ROLES - {"COMMUNITY_ADMIN", "STREET_SUPERVISOR"}))
def test_assignment_entry_denies_unauthorized_roles_before_sql(role):
    actor = Principal(101, "isolated", role, org_id=301, elder_id=401, caregiver_id=501)
    with pytest.raises(AccessDenied) as exc:
        Member5DAO().assign_auditor(None, actor, 1, 2)
    assert exc.value.status_code == 403


@pytest.mark.parametrize("role,stage", [("COMMUNITY_ADMIN", "待社区初审"), ("STREET_SUPERVISOR", "街道复审中")])
@pytest.mark.parametrize("stage_matches", [True, False])
def test_assignment_wrapper_checks_locked_stage_and_preserves_output(monkeypatch, role, stage, stage_matches):
    from . import member5_dao
    calls = []
    actor = Principal(101, "isolated", role, org_id=301)
    application = SimpleNamespace(audit_status=stage if stage_matches else "民政终审中",
                                  current_auditor_id=999)
    before = vars(application).copy()
    session = object()

    def lock(self, actual_session, actual_actor, application_id):
        assert actual_session is session and actual_actor is actor and application_id == 101
        calls.append("lock")
        return application

    monkeypatch.setattr(Member5DAO, "_lock_application", lock)

    def procedure(session, name, **values):
        calls.append((name, values))
        return SimpleNamespace(outputs={"assigned_to": 202})

    monkeypatch.setattr(member5_dao, "call_procedure", procedure)
    if stage_matches:
        # 即使原任务属于其他人，仍保留SQL支持的重新指派；Python不自行改归属。
        assert Member5DAO().assign_auditor(session, actor, 101, 202) == 202
        assert calls == ["lock", ("usp_M5_AssignAuditor", {"application_id": 101, "assignee_id": 202})]
    else:
        with pytest.raises(AccessDenied) as exc:
            Member5DAO().assign_auditor(session, actor, 101, 202)
        assert exc.value.status_code == 403
        assert calls == ["lock"]
    assert vars(application) == before


@pytest.mark.parametrize("role,stage", [("COMMUNITY_ADMIN", "待社区初审"), ("STREET_SUPERVISOR", "街道复审中")])
def test_assignment_rejects_other_roles_node(monkeypatch, role, stage):
    from . import member5_dao
    other_stage = "街道复审中" if stage == "待社区初审" else "待社区初审"
    monkeypatch.setattr(Member5DAO, "_lock_application",
                        lambda *_: SimpleNamespace(audit_status=other_stage))
    monkeypatch.setattr(member5_dao, "call_procedure", lambda *_a, **_k: pytest.fail("错节点不应调用过程"))
    with pytest.raises(AccessDenied) as exc:
        Member5DAO().assign_auditor(None, Principal(101, "isolated", role, org_id=301), 1, 2)
    assert exc.value.status_code == 403


@pytest.mark.parametrize("role,stage", [("COMMUNITY_ADMIN", "待社区初审"), ("STREET_SUPERVISOR", "街道复审中")])
@pytest.mark.parametrize("owner", [None, 101, 102])
@pytest.mark.parametrize("with_policy", [False, True])
def test_direct_audit_enforces_locked_owner_before_procedure(monkeypatch, role, stage, owner, with_policy):
    from . import member5_dao
    actor = Principal(101, "isolated", role, org_id=301, audit_org="测试审核单位")
    application = SimpleNamespace(audit_status=stage, current_auditor_id=owner)
    before, calls = vars(application).copy(), []

    def lock(self, actual_session, actual_actor, application_id):
        assert actual_session is session and actual_actor is actor and application_id == 301
        calls.append("lock")
        return application

    def procedure(actual_session, name, **values):
        assert actual_session is session
        calls.append((name, values))

    policy = SimpleNamespace(require_assigned=lambda *_: calls.append("policy")) if with_policy else None
    session = SimpleNamespace(flush=lambda: calls.append("flush"))
    monkeypatch.setattr(Member5DAO, "_lock_application", lock)
    monkeypatch.setattr(member5_dao, "call_procedure", procedure)
    dao = Member5DAO(task_policy=policy)
    if owner == 102:
        with pytest.raises(AccessDenied) as exc:
            dao.audit(session, actor, 301)
        assert exc.value.status_code == 403
        assert calls == ["lock"]  # 不执行可选策略、状态流转、日志写入或flush。
    else:
        dao.audit(session, actor, 301)
        expected = dict(application_id=301, before_status=stage,
            after_status="街道复审中" if role == "COMMUNITY_ADMIN" else "民政终审中",
            audit_node="社区初审" if role == "COMMUNITY_ADMIN" else "街道复审",
            audit_action="通过", auditor_id=101, auditor_org="测试审核单位", audit_opinion=None)
        assert calls == ["lock", *(["policy"] if with_policy else []),
                         ("usp_M5_AuditAdvance", expected), "flush"]
    # 存储过程被替换为无写入测试双，确认Python自身没有修改状态或current_auditor_id。
    assert vars(application) == before


def add_application(session, f, *, status="待社区初审", owner=None, month=1, policy=None):
    if policy is None:
        policy = SubsidyPolicy(policy_name=f["tag"], district_code="TEST", target_category="普通",
            service_item_id=f["item"].service_id, subsidy_mode="按次定额", subsidy_standard=40,
            settle_cycle="月", effective_date=f["now"].date())
        session.add(policy)
        session.flush()
    obj = SubsidyApplication(elder_id=f["elders"][0].elder_id, policy_id=policy.policy_id,
        settle_cycle=f"2098-{month:02d}", application_amount=0, create_by="V22Test",
        audit_status=status, current_auditor_id=owner, remark=f["tag"])
    session.add(obj)
    session.flush()
    return obj, policy


def test_real_todo_filter_and_locked_identity_refresh(session, fixture):
    f, dao = fixture, Member5DAO()
    comm, street = f["actors"]["COMMUNITY_ADMIN"], f["actors"]["STREET_SUPERVISOR"]
    a, policy = add_application(session, f)
    b, _ = add_application(session, f, owner=comm.user_id, month=2, policy=policy)
    c, _ = add_application(session, f, owner=street.user_id, month=3, policy=policy)
    d, _ = add_application(session, f, status="街道复审中", month=4, policy=policy)
    e, _ = add_application(session, f, status="街道复审中", owner=street.user_id, month=5, policy=policy)
    wrong_stage, _ = add_application(session, f, status="街道复审中", owner=comm.user_id, month=6, policy=policy)
    # The isolated DB can contain persistent integration fixtures. Assert the
    # rows created here are filtered correctly without assuming the global todo
    # queue is otherwise empty.
    comm_ids = [r.application_id for r in dao.audit_todos(session, comm, size=200)]
    street_ids = [r.application_id for r in dao.audit_todos(session, street, size=200)]
    assert {a.application_id, b.application_id}.issubset(comm_ids)
    assert c.application_id not in comm_ids and wrong_stage.application_id not in comm_ids
    assert {d.application_id, e.application_id}.issubset(street_ids)
    assert c.application_id not in street_ids
    # Page number is derived from the returned ordering so unrelated persistent
    # todos do not change which fixture row this assertion exercises.
    b_page = comm_ids.index(b.application_id) + 1
    assert [r.application_id for r in dao.audit_todos(session, comm, page=b_page, size=1)] == [b.application_id]
    for role in ROLES - {"COMMUNITY_ADMIN", "STREET_SUPERVISOR"}:
        with pytest.raises(AccessDenied):
            dao.audit_todos(session, f["actors"][role])
    with pytest.raises(ValueError):
        dao.audit_todos(session, comm, page=True)
    with pytest.raises(AccessDenied):
        dao.check_audit_task(session, comm, c.application_id)
    with pytest.raises(AccessDenied):
        dao.check_audit_task(session, street, a.application_id)
    assert dao.check_audit_task(session, comm, a.application_id)["current_auditor_id"] is None
    # Core写入仅用于隔离夹具制造ORM缓存过时；组件须在行锁内刷新真实归属。
    session.execute(text("UPDATE dbo.subsidy_application SET current_auditor_id=:owner WHERE application_id=:pk"),
                    {"owner": street.user_id, "pk": a.application_id})
    with pytest.raises(AccessDenied):
        dao.check_audit_task(session, comm, a.application_id)


@pytest.mark.parametrize("assigned", [False, True])
def test_real_component_and_single_node_audit_same_transaction(session, fixture, assigned):
    actor = fixture["actors"]["COMMUNITY_ADMIN"]
    application, _ = add_application(session, fixture, owner=actor.user_id if assigned else None)
    dao = Member5DAO()
    before = session.scalar(text("SELECT @@TRANCOUNT"))
    dao.check_audit_task(session, actor, application.application_id)
    # 固定归属检查同时由audit入口执行，终止动作也由SQL统一清空指派并写日志。
    dao.audit(session, actor, application.application_id, action="驳回", opinion="隔离节点测试")
    assert session.scalar(text("SELECT @@TRANCOUNT")) >= before
    logs = list(session.scalars(select(SubsidyAuditLog).where(SubsidyAuditLog.application_id == application.application_id)))
    assert len(logs) == 1 and logs[0].auditor_id == actor.user_id
    with pytest.raises(AccessDenied):
        dao.check_audit_task(session, actor, application.application_id)


@pytest.mark.parametrize("failure", ["role", "status", "missing"])
def test_real_assignment_procedure_rejects_invalid_targets(session, fixture, failure):
    app, _ = add_application(session, fixture, status="民政终审中" if failure == "status" else "待社区初审")
    assignee = fixture["actors"]["STREET_SUPERVISOR"].user_id
    if failure == "missing":
        # 从数据库查找不存在的测试编号，不把正式业务ID当常量。
        assignee = session.scalar(text("SELECT ISNULL(MAX(user_id),0)+1 FROM dbo.sys_user"))
    expected = {"role": "52173", "status": "52171", "missing": "52172"}[failure]
    with pytest.raises(pyodbc.Error, match=expected):
        call_procedure(session, "usp_M5_AssignAuditor", application_id=app.application_id, assignee_id=assignee)


def test_real_assignment_output_and_cross_node_clear(session, fixture):
    comm, street = fixture["actors"]["COMMUNITY_ADMIN"], fixture["actors"]["STREET_SUPERVISOR"]
    app, _ = add_application(session, fixture)
    result = call_procedure(session, "usp_M5_AssignAuditor", application_id=app.application_id, assignee_id=comm.user_id)
    assert result.outputs["assigned_to"] == comm.user_id
    Member5DAO().check_audit_task(session, comm, app.application_id)
    # 流转即清空；街道可办理下一节点，实际社区审核人保留在日志中。
    Member5DAO().audit(session, comm, app.application_id)
    session.refresh(app)
    assert (app.audit_status, app.current_auditor_id) == ("街道复审中", None)
    Member5DAO().check_audit_task(session, street, app.application_id)
    logs = list(session.scalars(select(SubsidyAuditLog).where(SubsidyAuditLog.application_id == app.application_id)))
    assert len(logs) == 1 and logs[0].auditor_id == comm.user_id
    # 数据库过程允许当前节点重新指派；此调用只用于隔离接口契约测试。
    assert call_procedure(session, "usp_M5_AssignAuditor", application_id=app.application_id,
                          assignee_id=street.user_id).outputs["assigned_to"] == street.user_id
    Member5DAO().audit(session, street, app.application_id)
    session.refresh(app)
    assert (app.audit_status, app.current_auditor_id) == ("民政终审中", None)


@pytest.mark.parametrize("role,stage", [("COMMUNITY_ADMIN", "待社区初审"), ("STREET_SUPERVISOR", "街道复审中")])
@pytest.mark.parametrize("owner", ["unassigned", "self", "other"])
def test_real_direct_audit_owner_and_unchanged_rejection(session, fixture, role, stage, owner):
    actor = fixture["actors"][role]
    other = SysUser(username=fixture["tag"] + "OTHER" + role, real_name="隔离审核员", role_code=role,
        org_id=actor.org_id, password_hash="+9w2RfX2uizSge3rQEsIPCnsyMt/TQGEqGYrcYxX38M=",
        password_salt="Pxr9DkGQx1zOIQ3v+GuGEw==")
    session.add(other)
    session.flush()
    owner_id = {"unassigned": None, "self": actor.user_id, "other": other.user_id}[owner]
    app, _ = add_application(session, fixture, status=stage, owner=owner_id)
    logs_query = select(SubsidyAuditLog).where(SubsidyAuditLog.application_id == app.application_id)
    before_logs = list(session.scalars(logs_query))
    dao = Member5DAO()  # task_policy=None仍强制检查归属。
    if owner == "other":
        with pytest.raises(AccessDenied) as exc:
            dao.audit(session, actor, app.application_id)
        assert exc.value.status_code == 403
        session.refresh(app)
        assert (app.audit_status, app.current_auditor_id) == (stage, owner_id)
        assert list(session.scalars(logs_query)) == before_logs
    else:
        dao.audit(session, actor, app.application_id)
        session.refresh(app)
        assert app.audit_status == ("街道复审中" if role == "COMMUNITY_ADMIN" else "民政终审中")
        assert app.current_auditor_id is None
        logs = list(session.scalars(logs_query))
        assert len(logs) == 1 and logs[0].auditor_id == actor.user_id


class RejectTaskPolicy:
    def require_assigned(self, *_):
        pytest.fail("抽查/整改不应执行预分配策略")


def test_real_inspection_and_rectification_ignore_assignment_policy(session, fixture):
    from .test_business import create_order, create_rectification
    f, dao = fixture, Member5DAO(task_policy=RejectTaskPolicy())
    assert dao.create_inspection(session, f["actors"]["CIVIL_SUPERVISOR"], object_type="护工",
        caregiver_id=f["caregivers"][0].caregiver_id, inspect_method="系统稽核", inspect_result="合格")
    oid = create_order(session, f)
    rid = create_rectification(session, f, oid, organization=True)
    dao.submit_rectification(session, f["actors"]["ORG_MANAGER"], rid)
    assert dao.review_rectification(session, f["actors"]["STREET_SUPERVISOR"], rid, "通过") == "N"


@pytest.fixture
def committed_env(database):
    from .conftest import build_fixture
    with database.session() as session:
        f = build_fixture(session)
        other = SysUser(username=f["tag"] + "COMM2", real_name="隔离审核员", role_code="COMMUNITY_ADMIN",
            org_id=f["orgs"][0].org_id, password_hash="+9w2RfX2uizSge3rQEsIPCnsyMt/TQGEqGYrcYxX38M=",
            password_salt="Pxr9DkGQx1zOIQ3v+GuGEw==")
        session.add(other)
        session.flush()
        f["other"] = replace(f["actors"]["COMMUNITY_ADMIN"], user_id=other.user_id, username=other.username)
        app, policy = add_application(session, f)
        f.update(application_id=app.application_id, policy_id=policy.policy_id)
        f["schedules"][0].max_orders = 4
        user_ids = [p.user_id for p in f["actors"].values()] + [other.user_id]
    try:
        yield f
    finally:
        # 只清理由本fixture创建且用实际ID定位的记录，不接触其他样例或预留订单。
        with database.session() as session:
            elder_ids = [e.elder_id for e in f["elders"]]
            cg_ids = [c.caregiver_id for c in f["caregivers"]]
            order_ids = select(ServiceOrder.order_id).where(ServiceOrder.elder_id.in_(elder_ids))
            inspection_condition = (QualityInspection.order_id.in_(order_ids)
                                    | QualityInspection.caregiver_id.in_(cg_ids))
            inspection_ids = select(QualityInspection.inspection_id).where(inspection_condition)
            for model, condition in [
                (Rectification, Rectification.inspection_id.in_(inspection_ids)),
                (QualityInspection, inspection_condition),
                (SubsidyAuditLog, SubsidyAuditLog.application_id == f["application_id"]),
                (SubsidyApplication, SubsidyApplication.application_id == f["application_id"]),
                (SubsidyPolicy, SubsidyPolicy.policy_id == f["policy_id"]),
                (DispatchRecord, DispatchRecord.order_id.in_(order_ids)),
                (ServiceOrder, ServiceOrder.elder_id.in_(elder_ids)),
                (SysUser, SysUser.user_id.in_(user_ids)),
                (CaregiverCertificate, CaregiverCertificate.caregiver_id.in_(cg_ids)),
                (CaregiverSchedule, CaregiverSchedule.caregiver_id.in_(cg_ids)),
                (Caregiver, Caregiver.caregiver_id.in_(cg_ids)),
                (ElderProfile, ElderProfile.elder_id.in_(elder_ids)),
                (ServiceOrg, ServiceOrg.org_id.in_([o.org_id for o in f["orgs"]])),
                (ServiceItem, ServiceItem.service_id == f["item"].service_id),
            ]:
                session.execute(delete(model).where(condition).execution_options(synchronize_session=False))


def wait_for_block(database, blocker, worker_info, ready):
    assert ready.wait(5)
    deadline = monotonic() + 5
    with database.engine.connect() as observer:
        while monotonic() < deadline:
            blocked_by = observer.scalar(text("SELECT blocking_session_id FROM sys.dm_exec_requests WHERE session_id=:pk"),
                                         {"pk": worker_info["spid"]})
            if blocked_by == blocker:
                return
            Event().wait(0.02)
    pytest.fail("未观测到同一申报行上的真实锁等待")


@pytest.mark.parametrize("commit_first", [True, False])
def test_real_concurrent_single_node_audit_component(database, committed_env, commit_first):
    f, dao = committed_env, Member5DAO()
    first = database.session_factory()
    ready, info = Event(), {}

    def second():
        try:
            with database.session() as session:
                session.execute(text("SET LOCK_TIMEOUT 10000"))
                info["spid"] = session.scalar(text("SELECT @@SPID"))
                ready.set()
                dao.check_audit_task(session, f["other"], f["application_id"])
                dao.audit(session, f["other"], f["application_id"], action="驳回", opinion="并发隔离测试")
            return "handled"
        except AccessDenied:
            return "denied"

    try:
        blocker = first.scalar(text("SELECT @@SPID"))
        dao.check_audit_task(first, f["actors"]["COMMUNITY_ADMIN"], f["application_id"])
        with ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(second)
            try:
                wait_for_block(database, blocker, info, ready)
                dao.audit(first, f["actors"]["COMMUNITY_ADMIN"], f["application_id"], action="驳回", opinion="首连接隔离测试")
            except Exception:
                first.rollback()
                raise
            else:
                first.commit() if commit_first else first.rollback()
            assert future.result(timeout=15) == ("denied" if commit_first else "handled")
        with database.session() as session:
            logs = list(session.scalars(select(SubsidyAuditLog).where(SubsidyAuditLog.application_id == f["application_id"])))
            assert len(logs) == 1
            assert logs[0].auditor_id == (f["actors"]["COMMUNITY_ADMIN"].user_id if commit_first else f["other"].user_id)
    finally:
        first.rollback()
        first.close()


def test_real_assignment_and_ownership_check_serialize(database, committed_env):
    f, ready, info = committed_env, Event(), {}
    writer = database.session_factory()

    def checker():
        with database.session() as session:
            session.execute(text("SET LOCK_TIMEOUT 10000"))
            info["spid"] = session.scalar(text("SELECT @@SPID"))
            ready.set()
            with pytest.raises(AccessDenied):
                Member5DAO().check_audit_task(session, f["actors"]["COMMUNITY_ADMIN"], f["application_id"])

    try:
        blocker = writer.scalar(text("SELECT @@SPID"))
        call_procedure(writer, "usp_M5_AssignAuditor", application_id=f["application_id"], assignee_id=f["other"].user_id)
        with ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(checker)
            try:
                wait_for_block(database, blocker, info, ready)
            finally:
                writer.commit()
            future.result(timeout=15)
    finally:
        writer.rollback()
        writer.close()


def test_real_concurrent_assignments_last_success_wins(database, committed_env):
    f, ready, info = committed_env, Event(), {}
    writer = database.session_factory()

    def assign_second():
        with database.session() as session:
            session.execute(text("SET LOCK_TIMEOUT 10000"))
            info["spid"] = session.scalar(text("SELECT @@SPID"))
            ready.set()
            return call_procedure(session, "usp_M5_AssignAuditor", application_id=f["application_id"],
                                  assignee_id=f["other"].user_id).outputs["assigned_to"]

    try:
        blocker = writer.scalar(text("SELECT @@SPID"))
        call_procedure(writer, "usp_M5_AssignAuditor", application_id=f["application_id"],
                       assignee_id=f["actors"]["COMMUNITY_ADMIN"].user_id)
        with ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(assign_second)
            try:
                wait_for_block(database, blocker, info, ready)
            finally:
                writer.commit()
            assert future.result(timeout=15) == f["other"].user_id
        with database.session() as session:
            assert session.get(SubsidyApplication, f["application_id"]).current_auditor_id == f["other"].user_id
    finally:
        writer.rollback()
        writer.close()


@pytest.mark.parametrize("operation", ["dispatch", "accept"])
def test_real_dispatch_serializes_with_organization_restriction(database, committed_env, operation):
    from .test_business import create_order, create_rectification
    f, ready, info = committed_env, Event(), {}
    with database.session() as session:
        oid = create_order(session, f)
        did = (Member2DAO().dispatch_order(session, f["actors"]["COMMUNITY_ADMIN"], oid,
               f["caregivers"][0].caregiver_id) if operation == "accept" else None)
    writer = database.session_factory()

    def dispatch_second():
        try:
            with database.session() as session:
                session.execute(text("SET LOCK_TIMEOUT 10000"))
                info["spid"] = session.scalar(text("SELECT @@SPID"))
                ready.set()
                if operation == "accept":
                    Member2DAO().accept_order(session, f["actors"]["CAREGIVER"], oid, did)
                else:
                    Member2DAO().dispatch_order(session, f["actors"]["COMMUNITY_ADMIN"], oid,
                                               f["caregivers"][0].caregiver_id)
        except pyodbc.Error as exc:
            assert "51121" in str(exc)
            return "restricted"
        return "dispatched"

    try:
        blocker = writer.scalar(text("SELECT @@SPID"))
        create_rectification(writer, f, oid, organization=True)
        with ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(dispatch_second)
            try:
                wait_for_block(database, blocker, info, ready)
            finally:
                writer.commit()
            assert future.result(timeout=15) == "restricted"
        with database.session() as session:
            assert session.get(ServiceOrder, oid).order_status == ("待接单" if operation == "accept" else "待派单")
            records = list(session.scalars(select(DispatchRecord).where(DispatchRecord.order_id == oid)))
            if operation == "accept":
                assert len(records) == 1 and records[0].dispatch_status == "待接单"
            else:
                assert not records
    finally:
        writer.rollback()
        writer.close()


def test_real_organization_three_states_without_reserved_orders(database, committed_env):
    from .test_business import create_order, create_rectification
    f, dao, orders = committed_env, Member5DAO(task_policy=RejectTaskPolicy()), Member2DAO()
    comm, care = f["actors"]["COMMUNITY_ADMIN"], f["actors"]["CAREGIVER"]
    with database.session() as session:
        original = create_order(session, f)
        did = orders.dispatch_order(session, comm, original, care.caregiver_id)
        orders.accept_order(session, care, original, did)
    with database.session() as session:
        rid = create_rectification(session, f, original, organization=True)
    with pytest.raises(pyodbc.Error, match="51121"):
        with database.session() as session:
            new_id = orders.create_order(session, comm, elder_id=f["elders"][0].elder_id,
                service_id=f["item"].service_id, appointment_time=f["appointment"] + timedelta(hours=1),
                service_address="测试社区1-三态测试")
            orders.dispatch_order(session, comm, new_id, care.caregiver_id)
    with database.session() as session:
        assert orders.orders.required(session, original, comm).order_status == "待服务"
        assert orders.dispatches.required(session, did, care).dispatch_status == "已接单"
        dao.submit_rectification(session, f["actors"]["ORG_MANAGER"], rid)
        assert orders.blocked_scope(session, comm, care.caregiver_id)["org"]
        assert dao.review_rectification(session, f["actors"]["STREET_SUPERVISOR"], rid, "通过") == "N"
    with database.session() as session:
        restored = orders.create_order(session, comm, elder_id=f["elders"][0].elder_id,
            service_id=f["item"].service_id, appointment_time=f["appointment"] + timedelta(hours=1),
            service_address="测试社区1-恢复派单测试")
        assert orders.dispatch_order(session, comm, restored, care.caregiver_id)


@pytest.mark.parametrize("organization", [False, True])
def test_real_restriction_blocks_accept_of_pending_dispatch(database, committed_env, organization):
    from .test_business import create_order, create_rectification
    f, dao = committed_env, Member2DAO()
    with database.session() as session:
        oid = create_order(session, f)
        did = dao.dispatch_order(session, f["actors"]["COMMUNITY_ADMIN"], oid,
                                 f["caregivers"][0].caregiver_id)
    with database.session() as session:
        rid = create_rectification(session, f, oid, organization=organization)
    with pytest.raises(pyodbc.Error, match="51121"):
        with database.session() as session:
            dao.accept_order(session, f["actors"]["CAREGIVER"], oid, did)
    with database.session() as session:
        assert session.get(ServiceOrder, oid).order_status == "待接单"
        dispatch = session.get(DispatchRecord, did)
        assert dispatch.dispatch_status == "待接单" and dispatch.accept_time is None
        assert session.get(Rectification, rid).restrict_flag == "Y"
