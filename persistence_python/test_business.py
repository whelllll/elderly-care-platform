from datetime import timedelta
from decimal import Decimal

import pyodbc
import pytest
from sqlalchemy import text

from .errors import AccessDenied
from .member1_dao import Member1DAO
from .member2_dao import Member2DAO
from .member3_dao import Member3DAO
from .member4_dao import Member4DAO
from .member5_dao import Member5DAO
from .models import DispatchRecord, WorkRecord


def create_order(session, f):
    return Member2DAO().create_order(session, f["actors"]["COMMUNITY_ADMIN"], elder_id=f["elders"][0].elder_id,
                                      service_id=f["item"].service_id, appointment_time=f["appointment"],
                                      service_address="测试社区1-测试地址", latitude=39.99, longitude=116.33, radius_m=100)


def dispatch_order(session, f, order_id):
    return Member2DAO().action(session, f["actors"]["COMMUNITY_ADMIN"], order_id, "DISPATCH",
                              caregiver_id=f["caregivers"][0].caregiver_id)


def create_rectification(session, f, order_id, *, organization=False):
    from .conftest import TestOnlyAssignmentPolicy
    actor = f["actors"]["CIVIL_SUPERVISOR"]
    values = dict(object_type="订单" if organization else "护工", order_id=order_id if organization else None,
                  caregiver_id=None if organization else f["caregivers"][0].caregiver_id,
                  inspect_method="系统稽核", inspect_time=f["now"],
                  inspect_result="不合格", rectify_flag="Y",
                  rectify_deadline=(f["now"] + timedelta(days=7)).date(), inspect_status="已完成")
    dao = Member5DAO(task_policy=TestOnlyAssignmentPolicy())
    inspection_id = dao.create_inspection(session, actor, **values)
    # 方案A未授权监管账号创建整改；隔离夹具使用正式过程准备限制，不能伪造角色授权。
    from .procedures import call_procedure
    return call_procedure(session, "usp_M5_CreateRectification", inspection_id=inspection_id,
                          org_id=f["orgs"][0].org_id,
                          caregiver_id=None if organization else f["caregivers"][0].caregiver_id,
                          problem_desc="隔离整改夹具", requirement="隔离测试整改",
                          deadline=(f["now"] + timedelta(days=7)).date()).outputs["rectify_id"]


def complete_order(session, f):
    dao, work = Member2DAO(), Member3DAO()
    actor = f["actors"]["CAREGIVER"]
    order_id = create_order(session, f)
    dispatch_id = dispatch_order(session, f, order_id)
    dao.action(session, actor, order_id, "ACCEPT", dispatch_id=dispatch_id)
    record = work.check_in(session, actor, dispatch_id, "39.99,116.33")
    work_id = record.work_id
    # 将本测试刚创建的签到回溯一小时，免去真实等待；不修改已有工时。
    record.check_in_time = session.scalar(text("SELECT DATEADD(HOUR,-1,SYSDATETIME())"))
    session.flush()
    dao.action(session, actor, order_id, "START", dispatch_id=dispatch_id)
    work.check_out(session, actor, dispatch_id, "39.99,116.33")
    work.review(session, f["actors"]["ORG_MANAGER"], work_id, approved=True, effective_minutes=30)
    dao.action(session, actor, order_id, "COMPLETE", dispatch_id=dispatch_id,
               confirmed=True, service_record="Python持久层整合测试完成服务")
    return order_id, dispatch_id, work_id


def test_member1_overview_multiple_result_sets(session, fixture):
    results = Member1DAO().overview(session, fixture["actors"]["COMMUNITY_ADMIN"], fixture["elders"][0].elder_id)
    assert results and results[0]


def test_order_inout_and_same_caregiver_full_shift_reassignment(session, fixture):
    f = fixture
    order_id = create_order(session, f)
    old = dispatch_order(session, f, order_id)
    before = session.scalar(text("SELECT @@TRANCOUNT"))
    new = Member2DAO().action(session, f["actors"]["COMMUNITY_ADMIN"], order_id, "REASSIGN",
                              caregiver_id=f["caregivers"][0].caregiver_id, dispatch_id=old, reason="同护工满班改派")
    assert new != old
    assert session.get(DispatchRecord, old).dispatch_status == "已撤回"
    assert session.get(DispatchRecord, new).dispatch_status == "待接单"
    assert session.scalar(text("SELECT @@TRANCOUNT")) == before
    assert Member2DAO().order_details(session, f["actors"]["COMMUNITY_ADMIN"], order_id)["order_id"] == order_id


def test_member2_create_scope_denial(session, fixture):
    f = fixture
    with pytest.raises(AccessDenied):
        Member2DAO().create_order(session, f["actors"]["FAMILY"], elder_id=f["elders"][1].elder_id,
                                  service_id=f["item"].service_id, appointment_time=f["appointment"],
                                  service_address="测试社区2-测试地址")


def test_member3_checkin_checkout_review_and_order_complete(session, fixture):
    order_id, _, work_id = complete_order(session, fixture)
    order = Member2DAO().orders.required(session, order_id, fixture["actors"]["FAMILY"])
    assert order.order_status == "已完成" and order.confirm_status == "已确认"
    assert session.get(WorkRecord, work_id).effective_minutes == 30


@pytest.mark.parametrize("organization", [False, True])
def test_real_rectification_blocks_dispatch_and_aborts_work_unit(session, fixture, database, organization):
    f = fixture
    order_id = create_order(session, f)
    create_rectification(session, f, order_id, organization=organization)
    blocked = Member2DAO().blocked_scope(session, f["actors"]["COMMUNITY_ADMIN"], f["caregivers"][0].caregiver_id)
    assert blocked["caregiver"]
    assert bool(blocked["org"]) == organization
    with pytest.raises(pyodbc.Error, match="51121"):
        dispatch_order(session, f, order_id)
    # Python持久层作为调用方执行全工作单元回滚，失败后不保留半成品订单。
    with database.engine.connect() as connection:
        assert connection.scalar(text("SELECT COUNT(*) FROM dbo.service_order WHERE order_id=:pk"), {"pk": order_id}) == 0


@pytest.mark.parametrize("organization", [False, True])
def test_real_rectification_submission_review_and_restored_dispatch(session, fixture, organization, test_task_policy):
    f = fixture
    order_id = create_order(session, f)
    rectify_id = create_rectification(session, f, order_id, organization=organization)
    dao = Member5DAO(task_policy=test_task_policy)
    dao.submit_rectification(session, f["actors"]["ORG_MANAGER"], rectify_id)
    flag = dao.review_rectification(session, f["actors"]["STREET_SUPERVISOR"], rectify_id, "通过")
    assert flag == "N"
    assert dispatch_order(session, f, order_id) is not None


def test_member4_emergency_lifecycle(session, fixture):
    f, dao = fixture, Member4DAO()
    actor = f["actors"]["COMMUNITY_ADMIN"]
    pk = dao.raise_emergency(session, actor, elder_id=f["elders"][0].elder_id,
                             trigger_source="主动上报", event_level="一般", happen_time=f["now"] - timedelta(minutes=2))
    dao.accept_emergency(session, actor, pk)
    dao.close_emergency(session, actor, pk, arrive_time=f["now"] - timedelta(minutes=1), dispose_result="测试处置完成")
    assert dao.emergencies.required(session, pk, actor).event_status == "已闭环"


def test_member5_application_detail_and_authorized_audit_stages(session, fixture, test_task_policy):
    f, dao = fixture, Member5DAO(task_policy=test_task_policy)
    order_id, _, work_id = complete_order(session, f)
    from .models import SubsidyPolicy
    # 仅在隔离测试事务中准备政策；正式矩阵未授权普通监管账号维护政策。
    policy = SubsidyPolicy(policy_name=f["tag"], district_code="TEST", target_category="普通",
                          service_item_id=f["item"].service_id, subsidy_mode="按次定额", subsidy_standard=40,
                          settle_cycle="月", effective_date=f["now"].date() - timedelta(days=365))
    session.add(policy)
    session.flush()
    pk = dao.create_application(session, f["actors"]["COMMUNITY_ADMIN"], elder_id=f["elders"][0].elder_id,
                                 policy_id=policy.policy_id, settle_cycle=f["appointment"].strftime("%Y-%m"))
    dao.add_item(session, f["actors"]["COMMUNITY_ADMIN"], pk, order_id=order_id,
                  subsidy_amount=40, self_pay_amount=40, work_id=work_id)
    application = dao.applications.required(session, pk, f["actors"]["COMMUNITY_ADMIN"])
    assert application.application_amount == Decimal("40.00") and application.order_count == 1
    with pytest.raises(AccessDenied):
        Member5DAO().audit(session, f["actors"]["STREET_SUPERVISOR"], pk)
    for role in ("COMMUNITY_ADMIN", "STREET_SUPERVISOR"):
        Member5DAO().audit(session, f["actors"][role], pk)
    with pytest.raises(AccessDenied):
        dao.audit(session, f["actors"]["CIVIL_SUPERVISOR"], pk)
    with pytest.raises(AccessDenied):
        dao.pay(session, f["actors"]["CIVIL_SUPERVISOR"], pk, f["tag"])
    assert application.audit_status == "民政终审中" and application.pay_status != "已拨付"
    traces = dao.subsidy_trace(session, f["actors"]["FAMILY"], pk)
    assert len(traces) == 1 and traces[0]["work_id"] == work_id
    logs = dao.audit_logs.page(session, f["actors"]["SYS_ADMIN"], filters={"application_id": pk})
    assert {row.auditor_id for row in logs} == {f["actors"][role].user_id for role in
               ("COMMUNITY_ADMIN", "STREET_SUPERVISOR")}
    assert all(row.auditor_org == "隔离测试监管单位" for row in logs)


def test_inspection_cannot_impersonate_another_account(session, fixture):
    f = fixture
    actor = f["actors"]["CIVIL_SUPERVISOR"]
    with pytest.raises(AccessDenied):
        Member5DAO().inspections.add(session, {"inspector_id": f["actors"]["STREET_SUPERVISOR"].user_id}, actor)


def test_community_admin_keeps_core_permissions_without_geographic_scope(session, fixture):
    from dataclasses import replace
    from .permissions import DataScope, require
    f = fixture
    actor = replace(f["actors"]["COMMUNITY_ADMIN"], scope=DataScope())
    for action in ("elder_profile:write", "order:dispatch", "subsidy:audit"):
        require(actor, action)
    pk = Member2DAO().create_order(session, actor, elder_id=f["elders"][0].elder_id,
         service_id=f["item"].service_id, appointment_time=f["appointment"], service_address="测试社区1-测试")
    assert Member2DAO().action(session, actor, pk, "DISPATCH", caregiver_id=f["caregivers"][0].caregiver_id)


def test_rectification_review_needs_no_unconfirmed_preassignment(session, fixture):
    from .models import Rectification
    f = fixture
    pk = create_order(session, f)
    rid = create_rectification(session, f, pk)
    Member5DAO().submit_rectification(session, f["actors"]["ORG_MANAGER"], rid)
    obj = session.get(Rectification, rid)
    obj.reviewer_id = f["actors"]["STREET_SUPERVISOR"].user_id
    session.flush()
    assert Member5DAO().review_rectification(session, f["actors"]["STREET_SUPERVISOR"], rid, "通过") == "N"


def test_default_inspection_needs_no_unconfirmed_preassignment(session, fixture):
    assert Member5DAO().create_inspection(session, fixture["actors"]["CIVIL_SUPERVISOR"], object_type="护工",
        caregiver_id=fixture["caregivers"][0].caregiver_id, inspect_method="系统稽核", inspect_result="合格")


def test_checkout_before_start_and_repeat_checkin_are_rejected(session, fixture):
    f, orders, work = fixture, Member2DAO(), Member3DAO()
    pk = create_order(session, f)
    did = dispatch_order(session, f, pk)
    actor = f["actors"]["CAREGIVER"]
    orders.action(session, actor, pk, "ACCEPT", dispatch_id=did)
    work.check_in(session, actor, did, "39.99,116.33")
    with pytest.raises(ValueError, match="START"):
        work.check_out(session, actor, did, "39.99,116.33")
    orders.action(session, actor, pk, "START", dispatch_id=did)
    with pytest.raises(ValueError, match="待服务"):
        work.check_in(session, actor, did, "39.99,116.33")
