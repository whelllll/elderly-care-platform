"""28个账号使用隔离夹具；不是实际B3账号迁移验收。"""
import json
from uuid import uuid4

import pytest
from sqlalchemy import select

from .errors import AccessDenied
from .models import SysUser
from .security import verify_password
from .security.accounts import (DEMO_HASH, DEMO_SALT, audit_b3_accounts, load_manifest,
                                secure_b3_accounts, validate_credentials, validate_entries,
                                configured_credentials, check_target_database)


def test_manifest_requires_exact_28_actual_unique_names(tmp_path):
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps({"accounts": [{"username": "same", "password_env": "SECRET"}] * 28}), encoding="utf-8")
    with pytest.raises(ValueError):
        load_manifest(path)


def test_28_independent_credentials_and_atomic_validation(session, fixture):
    tag = "B3ISOLATED:" + uuid4().hex[:12]
    credentials = {tag+str(i): "IsolatedPassword!"+str(i) for i in range(28)}
    rows = []
    for name in credentials:
        row = SysUser(username=name, real_name="隔离账号", password_hash=DEMO_HASH,
                      password_salt=DEMO_SALT, role_code="ELDER", elder_id=fixture["elders"][0].elder_id)
        session.add(row)
        rows.append(row)
    session.flush()
    identity_fields = ("user_id", "role_code", "org_id", "elder_id", "caregiver_id")
    identities = {row.username: {key: getattr(row, key) for key in identity_fields} for row in rows}
    unchanged_fields = (*identity_fields, "user_status", "login_fail_count", "lock_until", "last_login_time", "created_at")
    before = {row.username: tuple(getattr(row, key) for key in unchanged_fields) for row in rows}
    with pytest.raises(ValueError):
        audit_b3_accounts(session, credentials)
    with pytest.raises(AccessDenied):
        secure_b3_accounts(session, fixture["actors"]["COMMUNITY_ADMIN"], credentials)
    missing = dict(credentials)
    missing["does_not_exist:"+uuid4().hex] = missing.pop(next(iter(missing)))
    with pytest.raises(ValueError):
        secure_b3_accounts(session, fixture["actors"]["SYS_ADMIN"], missing)
    assert all(row.password_salt == DEMO_SALT for row in rows)
    wrong_identities = {name: dict(values) for name, values in identities.items()}
    wrong_identities[next(iter(wrong_identities))]["elder_id"] = -1
    with pytest.raises(ValueError, match="身份"):
        secure_b3_accounts(session, fixture["actors"]["SYS_ADMIN"], credentials,
                           expected_identities=wrong_identities)
    assert all(row.password_salt == DEMO_SALT for row in rows)
    report = secure_b3_accounts(session, fixture["actors"]["SYS_ADMIN"], credentials,
                                expected_identities=identities)
    assert report == {"accounts": 28, "unique_salts": 28, "unique_hashes": 28}
    actual = list(session.scalars(select(SysUser).where(SysUser.username.in_(credentials))))
    assert len(actual) == 28
    for row in actual:
        assert verify_password(credentials[row.username], row.password_hash, row.password_salt)
        assert row.elder_id == fixture["elders"][0].elder_id and row.user_status == "正常"
        assert row.pwd_update_time is not None
        assert tuple(getattr(row, key) for key in unchanged_fields) == before[row.username]


def valid_entries():
    return [dict(username=f"isolated_{i}", password_env=f"ISOLATED_PASSWORD_{i}",
                 expected=dict(user_id=i+1, role_code="ELDER", org_id=None, elder_id=501, caregiver_id=None))
            for i in range(28)]


@pytest.mark.parametrize("problem", ["root", "plaintext", "same_name", "same_env", "admin_env", "bad_env", "expected", "boolean_id", "missing_env"])
def test_manifest_preflight_rejects_invalid_configuration(tmp_path, problem):
    entries = valid_entries()
    if problem == "plaintext":
        entries[0]["password"] = "placeholder-only"
    elif problem == "same_name":
        entries[1]["username"] = entries[0]["username"].upper()
    elif problem == "same_env":
        entries[1]["password_env"] = entries[0]["password_env"].lower()
    elif problem == "admin_env":
        entries[0]["password_env"] = "B3_ADMIN_PASSWORD"
    elif problem == "bad_env":
        entries[0]["password_env"] = "NOT A VARIABLE"
    elif problem == "expected":
        entries[0].pop("expected")
    elif problem == "boolean_id":
        entries[0]["expected"]["user_id"] = True
    elif problem == "missing_env":
        entries[0].pop("password_env")
    document = [] if problem == "root" else {"accounts": entries}
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps(document), encoding="utf-8")
    with pytest.raises(ValueError):
        load_manifest(path, require_expected=True)


@pytest.mark.parametrize("problem", ["shared", "demo", "missing", "short", "count"])
def test_credentials_preflight_rejects_before_database(problem):
    from .permissions import Principal
    credentials = {f"isolated_{i}": "IsolatedOnly!" + str(i) for i in range(28)}
    if problem == "shared":
        credentials["isolated_1"] = credentials["isolated_0"]
    elif problem == "demo":
        credentials["isolated_0"] = "Admin@123"
    elif problem == "missing":
        credentials["isolated_0"] = None
    elif problem == "short":
        credentials["isolated_0"] = "short"
    else:
        credentials.pop("isolated_0")
    with pytest.raises(ValueError):
        secure_b3_accounts(None, Principal(1, "isolated_admin", "SYS_ADMIN"), credentials)


def test_offline_check_config_does_not_access_database(tmp_path, monkeypatch, capsys):
    import sys
    from .security.accounts import main
    from .db import Database
    entries = valid_entries()
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps({"accounts": entries}), encoding="utf-8")
    for i, entry in enumerate(entries):
        monkeypatch.setenv(entry["password_env"], "IsolatedOnly!" + str(i))
    monkeypatch.setattr(sys, "argv", ["accounts", "--manifest", str(path), "--check-config"])
    monkeypatch.setattr(Database, "initialize", lambda *_args, **_kwargs: pytest.fail("离线预检访问数据库"))
    main()
    assert json.loads(capsys.readouterr().out) == {"accounts": 28, "config_valid": True, "database_accessed": False}
    monkeypatch.delenv(entries[0]["password_env"])
    with pytest.raises(ValueError):
        configured_credentials(entries)


def test_apply_requires_confirmed_target_before_database(monkeypatch, capsys):
    import sys
    from .security.accounts import main
    monkeypatch.setattr(sys, "argv", ["accounts", "--manifest", "not-read.json", "--apply", "--admin", "admin"])
    with pytest.raises(SystemExit) as exc:
        main()
    assert exc.value.code == 2 and "--expected-database" in capsys.readouterr().err


def test_database_name_guard_rejects_mismatch():
    from contextlib import contextmanager
    from types import SimpleNamespace

    @contextmanager
    def session():
        yield SimpleNamespace(scalar=lambda *_: "IsolatedTest")

    db = SimpleNamespace(session=session)
    check_target_database(db, "IsolatedTest")
    with pytest.raises(ValueError, match="目标库"):
        check_target_database(db, "OtherDatabase")


def test_b3_startup_gate_with_isolated_28_accounts(database, monkeypatch, tmp_path):
    from .db import Database
    from .models import ElderProfile
    from .permissions import Principal
    tag = "B3STARTUP:" + uuid4().hex[:12]
    names = [tag+str(i) for i in range(28)]
    path = tmp_path / "b3-manifest.json"
    path.write_text(json.dumps({"accounts": [{"username": name, "password_env": "TEST_ONLY_"+str(i)}
                                               for i, name in enumerate(names)]}), encoding="utf-8")
    probe = Database(database.engine.url)
    monkeypatch.setenv("ELDERCARE_PROFILE", "B3")
    monkeypatch.delenv("ELDERCARE_B3_ACCOUNT_MANIFEST", raising=False)
    try:
        with pytest.raises(ValueError, match="MANIFEST"):
            probe.initialize()
        monkeypatch.setenv("ELDERCARE_B3_ACCOUNT_MANIFEST", str(path))
        with database.session() as session:
            elder_id = session.scalar(select(ElderProfile.elder_id).limit(1))
            admin = session.scalar(select(SysUser).where(SysUser.role_code == "SYS_ADMIN"))
            actor = Principal(admin.user_id, admin.username, admin.role_code)
            for name in names:
                session.add(SysUser(username=name, real_name="隔离启动测试", role_code="ELDER", elder_id=elder_id,
                                    password_salt=DEMO_SALT, password_hash=DEMO_HASH))
        with pytest.raises(ValueError, match="演示"):
            probe.initialize()
        with database.session() as session:
            secure_b3_accounts(session, actor, {name: "StartupTest!"+str(i) for i, name in enumerate(names)})
        assert probe.initialize() is probe
    finally:
        probe.close()
        with database.session() as session:
            for obj in session.scalars(select(SysUser).where(SysUser.username.in_(names))):
                session.delete(obj)
