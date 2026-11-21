"""28个账号使用隔离夹具；不是实际B3账号迁移验收。"""
import json
from uuid import uuid4

import pytest
from sqlalchemy import select

from .errors import AccessDenied
from .models import SysUser
from .security import verify_password
from .security.accounts import (DEMO_HASH, DEMO_SALT, audit_b3_accounts, load_manifest,
                                secure_b3_accounts)


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
    with pytest.raises(ValueError):
        audit_b3_accounts(session, credentials)
    with pytest.raises(AccessDenied):
        secure_b3_accounts(session, fixture["actors"]["COMMUNITY_ADMIN"], credentials)
    missing = dict(credentials)
    missing["does_not_exist:"+uuid4().hex] = missing.pop(next(iter(missing)))
    with pytest.raises(ValueError):
        secure_b3_accounts(session, fixture["actors"]["SYS_ADMIN"], missing)
    assert all(row.password_salt == DEMO_SALT for row in rows)
    report = secure_b3_accounts(session, fixture["actors"]["SYS_ADMIN"], credentials)
    assert report == {"accounts": 28, "unique_salts": 28, "unique_hashes": 28}
    actual = list(session.scalars(select(SysUser).where(SysUser.username.in_(credentials))))
    assert len(actual) == 28
    for row in actual:
        assert verify_password(credentials[row.username], row.password_hash, row.password_salt)
        assert row.elder_id == fixture["elders"][0].elder_id and row.user_status == "正常"
        assert row.pwd_update_time is not None


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
