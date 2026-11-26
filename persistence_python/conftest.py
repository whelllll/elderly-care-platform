"""真实SQL Server测试必须显式指定本轮专用库，默认跳过，不接触现有业务库。"""
import os
from datetime import date, timedelta
from uuid import uuid4

import pytest
from sqlalchemy import text
from sqlalchemy.engine import make_url

from .db import Database
from .models import (Caregiver, CaregiverCertificate, CaregiverSchedule, ElderProfile,
                     ServiceItem, ServiceOrg, SysUser)
from .permissions import DataScope, Principal


@pytest.fixture(scope="session")
def database():
    url = os.environ.get("ELDERCARE_TEST_DATABASE_URL")
    if not url:
        pytest.skip("未配置 ELDERCARE_TEST_DATABASE_URL，未运行真实SQL Server测试。")
    if not (make_url(url).database or "").startswith("Codex_Persistence_"):
        pytest.fail("集成测试只允许连接Codex_Persistence_前缀的专用测试库。")
    db = Database(url).initialize(validate_b3=False)  # 仅允许上述前缀的隔离测试库；B3启动另有专用用例。
    yield db
    db.close()


@pytest.fixture
def session(database):
    obj = database.session_factory()
    obj.begin()
    yield obj
    obj.rollback()
    obj.close()


@pytest.fixture
def fixture(session):
    return build_fixture(session)


def build_fixture(session):
    tag = "PY:" + uuid4().hex[:16]
    now = session.scalar(text("SELECT SYSDATETIME()"))
    start = (now + timedelta(days=3)).replace(microsecond=0)

    def row(model, **values):
        obj = model(**values)
        session.add(obj)
        session.flush()
        return obj

    orgs = [row(ServiceOrg, org_name=tag + str(i), contact_person="Python测试", contact_phone="13800000001",
                org_address=tag + str(i), service_area="测试社区" + str(i)) for i in (1, 2)]
    elders = [row(ElderProfile, elder_name=tag + str(i), id_card_no=f"{uuid4().int % 10**18:018d}",
                  birth_date=date(1940, 1, 1), address="测试地址", community_name="测试社区" + str(i)) for i in (1, 2)]
    caregivers = [row(Caregiver, caregiver_name=tag + str(i), org_id=orgs[i-1].org_id,
                      phone="13800000001", service_area="测试社区" + str(i)) for i in (1, 2)]
    item = row(ServiceItem, service_name=tag, service_type="家政", price=80, duration=30, charge_unit="次")
    schedules = []
    for cg in caregivers:
        row(CaregiverCertificate, caregiver_id=cg.caregiver_id, certificate_no=tag,
            certificate_type="养老护理员", service_id=item.service_id, qualification_level="初级",
            # Some real integration cases schedule across midnight (e.g. 20 orders
            # at 10-minute intervals from 23:19); keep the test credential valid
            # through the following date so those cases test dispatch, not expiry.
            valid_from=start.date(), valid_to=(start + timedelta(days=1)).date(), certificate_status="有效")
        schedules.append(row(CaregiverSchedule, caregiver_id=cg.caregiver_id, start_time=start,
                             end_time=start + timedelta(hours=8), max_orders=1, schedule_status="开放"))
    scope = DataScope(frozenset({"测试社区1"}), frozenset({orgs[0].org_id}), frozenset({"TEST"}))
    actors = {}
    for role, binding in [
        ("SYS_ADMIN", {}), ("COMMUNITY_ADMIN", {"org_id": orgs[0].org_id}),
        ("ORG_MANAGER", {"org_id": orgs[0].org_id}), ("ELDER", {"elder_id": elders[0].elder_id}),
        ("FAMILY", {"elder_id": elders[0].elder_id}), ("CAREGIVER", {"caregiver_id": caregivers[0].caregiver_id}),
        ("STREET_SUPERVISOR", {}), ("CIVIL_SUPERVISOR", {})]:
        u = row(SysUser, username=tag + role, password_hash="+9w2RfX2uizSge3rQEsIPCnsyMt/TQGEqGYrcYxX38M=",
                password_salt="Pxr9DkGQx1zOIQ3v+GuGEw==", real_name="Python测试", role_code=role, **binding)
        actors[role] = Principal(u.user_id, u.username, role, u.org_id, u.elder_id, u.caregiver_id, scope,
                                 audit_org="隔离测试监管单位")
    return dict(tag=tag, now=now, start=start, appointment=start + timedelta(hours=1), orgs=orgs,
                elders=elders, caregivers=caregivers, item=item, schedules=schedules, actors=actors)


class TestOnlyAssignmentPolicy:
    """仅验证业务入口调用顺序的测试双，不代表正式数据库已实现任务分配。"""
    __test__ = False

    def require_assigned(self, session, actor, operation, target_id):
        from .permissions import require
        # 只验证这个依赖被显式注入；真实分配验收必须等待成员5提供正式依据。
        require(actor, "service_item:read")


@pytest.fixture
def test_task_policy():
    return TestOnlyAssignmentPolicy()
