from types import SimpleNamespace

import pytest

from .errors import AccessDenied, AuthenticationError
from .permissions import DataScope, Principal, require
from .security import SessionStore, hash_password, verify_password


def test_password_compatibility_and_random_salt():
    assert verify_password("Admin@123", "+9w2RfX2uizSge3rQEsIPCnsyMt/TQGEqGYrcYxX38M=", "Pxr9DkGQx1zOIQ3v+GuGEw==")
    first, salt = hash_password("测试Password123!")
    assert verify_password("测试Password123!", first, salt)
    assert not verify_password("wrong", first, salt)
    assert salt != hash_password("测试Password123!")[1]


@pytest.mark.parametrize("value", [None, "bad!", "", "AAAA"])
def test_malformed_password_records_fail_closed(value):
    assert not verify_password("password", value, value)


def test_short_password_rejected():
    with pytest.raises(ValueError):
        hash_password("short")


def test_scope_copies_mutable_configuration():
    orgs = {1}
    scope = DataScope(org_ids=orgs)
    orgs.add(2)
    assert scope.org_ids == frozenset({1})


@pytest.mark.parametrize("actor,action", [
    (Principal(1, "admin", "SYS_ADMIN"), "order:dispatch"),
    (Principal(1, "care", "CAREGIVER", caregiver_id=1), "order:reassign"),
    (Principal(1, "invalid", "UNKNOWN"), "service_item:read"),
])
def test_role_denials(actor, action):
    with pytest.raises(AccessDenied):
        require(actor, action)


@pytest.mark.parametrize("role,action", [
    ("STREET_SUPERVISOR", "elder_profile:write"),
    ("STREET_SUPERVISOR", "order:dispatch"),
    ("STREET_SUPERVISOR", "quality_inspection:write"),
    ("STREET_SUPERVISOR", "subsidy_policy:write"),
    ("CIVIL_SUPERVISOR", "elder_profile:write"),
    ("CIVIL_SUPERVISOR", "order:dispatch"),
    ("CIVIL_SUPERVISOR", "subsidy_policy:write"),
    ("CIVIL_SUPERVISOR", "rectification:review"),
    ("SYS_ADMIN", "subsidy:audit"),
])
def test_supervisor_and_system_roles_do_not_gain_ordinary_write(role, action):
    with pytest.raises(AccessDenied):
        require(Principal(1, "role-test", role), action)


@pytest.mark.parametrize("role,action", [
    ("COMMUNITY_ADMIN", "elder_profile:write"),
    ("COMMUNITY_ADMIN", "order:dispatch"),
    ("COMMUNITY_ADMIN", "subsidy:audit"),
    ("STREET_SUPERVISOR", "rectification:review"),
    ("STREET_SUPERVISOR", "subsidy:audit"),
    ("CIVIL_SUPERVISOR", "quality_inspection:write"),
    ("CIVIL_SUPERVISOR", "subsidy:audit"),
    ("SYS_ADMIN", "account:manage"),
])
def test_preserved_explicit_role_grants(role, action):
    require(Principal(1, "role-test", role, org_id=1), action)


def test_session_logout_and_expiration():
    actor = Principal(1, "test", "ELDER", elder_id=1)
    service = SimpleNamespace(login=lambda username, password: actor, actor_for_user=lambda session, user_id: actor)
    store = SessionStore(service, ttl_seconds=10)
    token = store.login("user", "password")
    assert token not in store._sessions
    assert store.resolve(None, token) == actor
    store.logout(token)
    with pytest.raises(AuthenticationError):
        store.resolve(None, token)


def test_unauthenticated_requires_401():
    with pytest.raises(AuthenticationError) as error:
        require(None, "elder_profile:read")
    assert error.value.status_code == 401


def test_session_idle_and_absolute_boundaries_and_identity_refresh():
    from dataclasses import replace
    clock = [0.0]
    actor = Principal(1, "test", "FAMILY", org_id=3, elder_id=4, auth_version="v1")
    current = [actor]
    service = SimpleNamespace(login=lambda *args: current[0], actor_for_user=lambda *args: current[0])
    store = SessionStore(service, clock=lambda: clock[0])
    token = store.login("user", "password")
    entry = store._sessions[store._digest(token)]
    assert (entry.principal.user_id, entry.principal.role_code, entry.principal.org_id,
            entry.principal.elder_id, entry.principal.caregiver_id) == (1, "FAMILY", 3, 4, None)
    clock[0] = 1799
    current[0] = replace(actor, elder_id=5)
    assert store.resolve(None, token).elder_id == 5
    clock[0] = 3598  # 活动滑动续期，每次间隔小于30分钟。
    store.resolve(None, token)
    clock[0] = 5398
    with pytest.raises(AuthenticationError):
        store.resolve(None, token)  # 正好空闲1800秒即过期。
    clock[0] = 0
    token = store.login("user", "password")
    for instant in range(1700, 28800, 1700):
        clock[0] = instant
        store.resolve(None, token)
    clock[0] = 28800
    with pytest.raises(AuthenticationError):
        store.resolve(None, token)  # 持续活动也不能超过8小时。
    token = store.login("user", "password")
    current[0] = replace(current[0], auth_version="v2")
    with pytest.raises(AuthenticationError):
        store.resolve(None, token)


def test_actual_login_failures_lockout_and_revocation(database):
    from datetime import timedelta
    from uuid import uuid4
    from sqlalchemy import select, text
    from .models import SysUser
    from .security import LoginService

    name = "PYLOGIN:" + uuid4().hex[:16]
    digest, salt = hash_password("TestPassword123!")
    with database.session() as session:
        obj = SysUser(username=name, password_hash=digest, password_salt=salt, real_name="登录测试", role_code="SYS_ADMIN")
        session.add(obj)
        session.flush()
        pk = obj.user_id
    login = LoginService(database)
    try:
        store = SessionStore(login)
        token = store.login(name, "TestPassword123!")
        for _ in range(5):
            with pytest.raises(AuthenticationError):
                login.login(name, "wrong")
        with database.session() as session:
            obj = session.get(SysUser, pk)
            assert obj.login_fail_count == 5 and obj.user_status == "锁定" and obj.lock_until is not None
            locked_until = obj.lock_until
            now = session.scalar(text("SELECT SYSDATETIME()"))
            assert 1790 <= (locked_until - now).total_seconds() <= 1801  # DATETIME2(0)秒精度。
            with pytest.raises(AuthenticationError):
                store.resolve(session, token)
        with pytest.raises(AuthenticationError):
            login.login(name, "TestPassword123!")
        with database.session() as session:
            obj = session.get(SysUser, pk)
            assert obj.lock_until == locked_until and obj.login_fail_count == 5
            obj.lock_until = now - timedelta(seconds=1)
        with pytest.raises(AuthenticationError):
            login.login(name, "wrong")
        with database.session() as session:
            obj = session.get(SysUser, pk)
            assert obj.user_status == "正常" and obj.login_fail_count == 1 and obj.lock_until is None
        actor = login.login(name, "TestPassword123!")
        with database.session() as session:
            obj = session.get(SysUser, pk)
            assert obj.login_fail_count == 0 and obj.last_login_time is not None
        token = store.login(name, "TestPassword123!")
        with database.session() as session:
            old_salt = session.get(SysUser, pk).password_salt
            login.change_password(session, actor, "TestPassword123!", "NewPassword123!")
            assert session.get(SysUser, pk).password_salt != old_salt
        with database.session() as session:
            with pytest.raises(AuthenticationError):
                store.resolve(session, token)
        with pytest.raises(AuthenticationError):
            login.login(name, "TestPassword123!")
        assert login.login(name, "NewPassword123!").user_id == pk
        active_token = store.login(name, "NewPassword123!")
        with database.session() as session:
            obj = session.get(SysUser, pk)
            # CK_user_lock规定非锁定账号lock_until必须为空，不能伪造非法状态。
            obj.user_status, obj.lock_until = "停用", None
        with pytest.raises(AuthenticationError):
            login.login(name, "NewPassword123!")
        with database.session() as session:
            assert session.get(SysUser, pk).user_status == "停用"
            with pytest.raises(AuthenticationError):
                store.resolve(session, active_token)
    finally:
        # 仅删除本测试创建且由唯一用户名定位的临时账号。
        with database.session() as session:
            obj = session.scalar(select(SysUser).where(SysUser.user_id == pk, SysUser.username == name))
            session.delete(obj)
