"""本轮独立测试与隔离SQL批次测试；不写正式20条订单。"""
from contextlib import contextmanager
from datetime import datetime, timedelta
from pathlib import Path
import re
from types import SimpleNamespace

import pytest

from .errors import AccessDenied, AuthenticationError
from .member2_dao import Member2DAO
from .member5_dao import Member5DAO
from .order_batch import execute_batch, preflight
from .order_validation import validate_order, validate_action
from .permissions import Principal, require
from .permissions.roles import BUSINESS, STAFF_READ, WRITE
from .security import LoginService, SessionStore, hash_password, verify_password
from .security.accounts import audit_b3_accounts
from .security.http import AuthenticationMiddleware


def fake_user_table(monkeypatch, module):
    from sqlalchemy import column, table
    user = table("sys_user", column("username"), column("user_id"))
    user.username, user.user_id = user.c.username, user.c.user_id
    monkeypatch.setattr(module, "SysUser", user)


MATRIX = {
    "STREET_SUPERVISOR": {"subsidy:audit", "subsidy:street_audit", "subsidy:assign", "rectification:review", "account:password"},
    "CIVIL_SUPERVISOR": {"account:password"},
}


@pytest.mark.parametrize("role", MATRIX)
def test_complete_supervisor_action_matrix(role):
    actor = Principal(1, "test", role)
    for action in BUSINESS:
        if action in MATRIX[role]:
            require(actor, action)
        else:
            with pytest.raises(AccessDenied):
                require(actor, action)
    for resource in STAFF_READ:
        require(actor, resource + ":read")
    for resource in set().union(*WRITE.values()) | {"unknown"}:
        if role == "CIVIL_SUPERVISOR" and resource == "quality_inspection":
            require(actor, resource + ":write")
        else:
            with pytest.raises(AccessDenied):
                require(actor, resource + ":write")


@pytest.mark.parametrize("role", MATRIX)
@pytest.mark.parametrize("operation", ["create_order", "dispatch_order", "accept_order", "pay", "create_rectification"])
def test_denied_dao_entries_return_http_403_before_database(role, operation):
    actor = Principal(1, "test", role)

    @contextmanager
    def session():
        yield None  # 任何SQL访问都会失败，证明先执行授权检查。

    def app(environ, start_response):
        orders, regulator = Member2DAO(), Member5DAO()
        if operation == "create_order":
            orders.create_order(None, actor, elder_id=1, service_id=1,
                appointment_time=datetime(2099, 1, 1), service_address="社区-地址")
        elif operation == "dispatch_order":
            orders.dispatch_order(None, actor, 1, 1)
        elif operation == "accept_order":
            orders.accept_order(None, actor, 1, 1)
        elif operation == "pay":
            regulator.pay(None, actor, 1, "voucher")
        else:
            regulator.create_rectification(None, actor, inspection_id=1, org_id=1)
        raise AssertionError("未拒绝未授权入口")

    middleware = AuthenticationMiddleware(app, SimpleNamespace(session=session),
                                         SimpleNamespace(resolve=lambda *_: actor))
    result = {}
    middleware({"HTTP_AUTHORIZATION": "Bearer token"}, lambda status, *args: result.update(status=status))
    assert result["status"] == "403 Forbidden"


def test_member4_all_28_published_credentials_compatible_but_not_secure_initialization(monkeypatch):
    from .security import accounts
    fake_user_table(monkeypatch, accounts)
    sql = (Path(__file__).parents[1] / "member4" / "13_b3_accounts_28.sql").read_text(encoding="utf-8-sig")
    pairs = re.findall(r"\(\d+, '([^']+)', '([^']+)'\)", sql)
    assert len(pairs) == 28 and len({salt for salt, _ in pairs}) == len({digest for _, digest in pairs}) == 28
    demo = re.search(r"测试密码：(\S+)", sql).group(1)
    assert all(verify_password(demo, digest, salt) for salt, digest in pairs)
    rows = [SimpleNamespace(password_salt=salt, password_hash=digest) for salt, digest in pairs]
    with pytest.raises(ValueError, match="演示"):
        audit_b3_accounts(SimpleNamespace(scalars=lambda *_: rows), [f"user{i}" for i in range(28)])


def test_login_lockout_disabled_expiry_and_session_identity_without_database(monkeypatch):
    from .security import login as login_module
    fake_user_table(monkeypatch, login_module)
    digest, salt = hash_password("IsolatedLogin123!")
    now = datetime(2026, 11, 22, 12)
    obj = SimpleNamespace(user_id=7, username="actual_username", role_code="CAREGIVER", org_id=13,
                          caregiver_id=29, elder_id=None, user_status="正常", lock_until=None,
                          login_fail_count=0, password_hash=digest, password_salt=salt)

    class FakeSession:
        def scalar(self, statement):
            if str(statement) == "SELECT SYSDATETIME()":
                return now
            assert "username" in str(statement) or "user_id" in str(statement)
            return obj

    @contextmanager
    def session():
        yield FakeSession()

    login = LoginService(SimpleNamespace(session=session))
    for count in range(1, 6):
        with pytest.raises(AuthenticationError):
            login.login(obj.username, "wrong")
        assert obj.login_fail_count == count
    assert obj.user_status == "锁定" and obj.lock_until == now + timedelta(minutes=30)
    with pytest.raises(AuthenticationError):
        login.login(obj.username, "IsolatedLogin123!")
    obj.lock_until = now
    store = SessionStore(login)
    token = store.login(obj.username, "IsolatedLogin123!")
    actor = store.resolve(FakeSession(), token)
    assert (actor.user_id, actor.role_code, actor.org_id, actor.elder_id, actor.caregiver_id) == (7, "CAREGIVER", 13, None, 29)
    assert obj.login_fail_count == 0 and obj.lock_until is None and obj.user_status == "正常"
    obj.user_status = "停用"
    with pytest.raises(AuthenticationError):
        login.login(obj.username, "IsolatedLogin123!")
    with pytest.raises(AuthenticationError):
        store.resolve(FakeSession(), token)


@pytest.mark.parametrize("changes", [
    {"elder_id": True}, {"service_id": 0}, {"appointment_time": "tomorrow"},
    {"service_address": "社区- "}, {"service_address": " 社区-地址"},
    {"latitude": 1}, {"latitude": "NaN", "longitude": 1, "radius_m": 10},
    {"latitude": 91, "longitude": 1, "radius_m": 10}, {"order_channel": "unknown"},
])
def test_bad_order_parameters_rejected(changes):
    values = dict(elder_id=105, service_id=204, appointment_time=datetime(2099, 1, 1), service_address="社区-地址")
    with pytest.raises(ValueError):
        validate_order(**(values | changes))


def test_dispatch_and_accept_require_actual_ids_and_batch_acceptance_gate():
    for action, cg, dispatch in [("DISPATCH", None, None), ("ACCEPT", None, None), ("REASSIGN", 5, 0)]:
        with pytest.raises(ValueError):
            validate_action(1, action, cg, dispatch, None, False, None)
    with pytest.raises(ValueError, match="B1/B2"):
        execute_batch(None, None, {}, {})


def test_create_dispatch_accept_preserve_procedure_outputs_and_ownership(monkeypatch):
    from . import member2_dao
    from .base_dao import BaseDAO
    calls = []
    rows = {"elder_profile": SimpleNamespace(), "service_item": SimpleNamespace(),
            "service_order": SimpleNamespace(order_id=501), "caregiver": SimpleNamespace(),
            "dispatch_record": SimpleNamespace(order_id=501, caregiver_id=703)}
    monkeypatch.setattr(BaseDAO, "required", lambda self, *_: rows[self.table])

    def procedure(session, name, **values):
        calls.append((name, values))
        return SimpleNamespace(outputs={"OrderID": 501, "DispatchID": 902})

    monkeypatch.setattr(member2_dao, "call_procedure", procedure)
    actor = Principal(1, "community", "COMMUNITY_ADMIN", org_id=301)
    caregiver = Principal(2, "caregiver", "CAREGIVER", org_id=301, caregiver_id=703)
    dao = Member2DAO()
    oid = dao.create_order(None, actor, elder_id=409, service_id=208,
        appointment_time=datetime(2099, 1, 1), service_address="社区-地址")
    did = dao.dispatch_order(None, actor, oid, caregiver.caregiver_id)
    assert dao.accept_order(None, caregiver, oid, did) == 902
    assert calls[0][0] == "usp_M2_CreateOrder"
    assert calls[1][1]["OrderID"] == calls[2][1]["OrderID"] == oid
    assert calls[2][1]["DispatchID"] == did and calls[2][1]["Action"] == "ACCEPT"
    rows["dispatch_record"].order_id = 999
    with pytest.raises(AccessDenied):
        dao.accept_order(None, caregiver, oid, did)
    rows["dispatch_record"].order_id, rows["dispatch_record"].caregiver_id = oid, 999
    with pytest.raises(AccessDenied):
        dao.accept_order(None, caregiver, oid, did)
    assert len(calls) == 3


def isolated_batch(f, session):
    from dataclasses import replace
    from .models import SysUser
    caregiver = f["actors"]["CAREGIVER"]
    org_id = f["caregivers"][0].org_id
    session.get(SysUser, caregiver.user_id).org_id = org_id
    f["actors"]["CAREGIVER"] = replace(caregiver, org_id=org_id)
    f["item"].duration = 10
    f["schedules"][0].max_orders = 20
    return {"batch": f["tag"].replace(":", "_"), "orders": [dict(
        elder_id=f["elders"][0].elder_id, service_id=f["item"].service_id,
        caregiver_id=f["caregivers"][0].caregiver_id, schedule_id=f["schedules"][0].schedule_id,
        caregiver_username=f["actors"]["CAREGIVER"].username, password_env="ISOLATED_ONLY",
        appointment_time=f["appointment"] + timedelta(minutes=10*i), service_address="测试社区1-专用批次地址")
        for i in range(20)]}


def test_real_isolated_20_order_batch_and_repeat_rejection(session, fixture):
    batch = isolated_batch(fixture, session)
    session.flush()
    actor = fixture["actors"]["COMMUNITY_ADMIN"]
    assert preflight(session, actor, batch)["orders"] == 20
    result = execute_batch(session, actor, batch,
        {fixture["actors"]["CAREGIVER"].username: fixture["actors"]["CAREGIVER"]}, b1_b2_accepted=True)
    assert len(result) == len({r["order_id"] for r in result}) == len({r["dispatch_id"] for r in result}) == 20
    with pytest.raises(ValueError, match="批次已存在"):
        preflight(session, actor, batch)


def test_real_batch_failure_rolls_back_entire_batch(session, fixture, monkeypatch):
    from sqlalchemy import text
    batch = isolated_batch(fixture, session)
    session.flush()
    original = Member2DAO.accept_order
    calls = []

    def fail_fifth(self, *args, **kwargs):
        calls.append(1)
        if len(calls) == 5:
            raise ValueError("隔离故障注入")
        return original(self, *args, **kwargs)

    monkeypatch.setattr(Member2DAO, "accept_order", fail_fifth)
    with pytest.raises(ValueError, match="隔离故障"):
        execute_batch(session, fixture["actors"]["COMMUNITY_ADMIN"], batch,
            {fixture["actors"]["CAREGIVER"].username: fixture["actors"]["CAREGIVER"]}, b1_b2_accepted=True)
    assert session.scalar(text("SELECT COUNT(*) FROM dbo.service_order WHERE remark=:mark"),
                          {"mark": "M2:BATCH:" + batch["batch"]}) == 0


def test_real_isolated_b3_28_logins_and_expected_session_bindings(session, fixture, monkeypatch):
    from .models import SysUser, Caregiver
    from .security.verify_b3 import verify_accounts
    f = fixture
    rows = [session.get(SysUser, actor.user_id) for actor in f["actors"].values()]
    next(row for row in rows if row.role_code == "CAREGIVER").org_id = f["orgs"][0].org_id
    for i in range(19):
        org = f["orgs"][i % 2]
        cg = Caregiver(caregiver_name=f["tag"] + str(i), org_id=org.org_id,
                       phone="13800000001", service_area=org.service_area)
        session.add(cg)
        session.flush()
        rows.append(SysUser(username=f["tag"] + "b3care" + str(i), real_name="隔离B3账号", role_code="CAREGIVER",
                            caregiver_id=cg.caregiver_id, org_id=org.org_id))
    rows.append(SysUser(username=f["tag"] + "b3org", real_name="隔离B3机构", role_code="ORG_MANAGER",
                        org_id=f["orgs"][1].org_id))
    entries = []
    for i, row in enumerate(rows):
        password = "IsolatedB3Test!" + str(i)
        row.password_hash, row.password_salt = hash_password(password)
        session.add(row)
        session.flush()
        env = "ISOLATED_B3_TEST_" + str(i)
        monkeypatch.setenv(env, password)
        entries.append(dict(username=row.username, password_env=env,
                            expected={key: getattr(row, key) for key in
                                      ("user_id", "role_code", "org_id", "elder_id", "caregiver_id")}))

    @contextmanager
    def same_transaction():
        yield session  # 真实SQL Server；全部隔离账号及登录更新在测试结束统一回滚。

    report = verify_accounts(SimpleNamespace(session=same_transaction), entries)
    assert report == {"accounts": 28, "login_pass": 28, "session_identity_pass": 28}
    entries[0]["expected"]["org_id"] = f["orgs"][1].org_id
    with pytest.raises(ValueError, match="身份不符"):
        verify_accounts(SimpleNamespace(session=same_transaction), entries)
