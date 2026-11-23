"""B3离线单元测试：模拟事务不代表真实SQL Server回滚验收。"""
from contextlib import contextmanager
from copy import deepcopy
from datetime import datetime
import json
import os
from types import SimpleNamespace

import pytest
from sqlalchemy import column, table

from .db import Database
from .permissions import Principal
from .security import accounts
from .security.credentials import create_credential_file, generate_passwords, load_credentials, external_path
from .security.password import hash_password, verify_password
from .test_accounts import valid_entries


def test_template_can_prepare_slots_before_actual_identity_is_known():
    from pathlib import Path
    template = Path(__file__).parent / "security" / "b3-accounts.template.json"
    entries = json.loads(template.read_text(encoding="utf-8"))["accounts"]
    assert len(generate_passwords(entries)) == 28
    with pytest.raises(ValueError):
        accounts.validate_b3_contract(entries)


def test_28_random_passwords_salts_hashes_and_verification():
    entries = valid_entries()
    values = generate_passwords(entries)
    assert len(set(values.values())) == 28
    prepared = [hash_password(value) for value in values.values()]
    assert len({digest for digest, _ in prepared}) == 28
    assert len({salt for _, salt in prepared}) == 28
    import base64
    assert all(len(base64.b64decode(salt, validate=True)) == 16 for _, salt in prepared)
    assert all(len(base64.b64decode(digest, validate=True)) == 32 for digest, _ in prepared)
    assert all(verify_password(value, *pair) for value, pair in zip(values.values(), prepared))
    assert all(not verify_password(value + "-wrong", *pair) for value, pair in zip(values.values(), prepared))


def test_random_generator_collision_is_bounded(monkeypatch):
    from .security import credentials
    monkeypatch.setattr(credentials.secrets, "token_urlsafe", lambda *_: "RepeatedTestOnlyPassword")
    with pytest.raises(ValueError, match="独立"):
        generate_passwords(valid_entries())


@pytest.mark.skipif(os.name != "nt", reason="Windows current-user DPAPI required")
def test_dpapi_roundtrip_no_plaintext_and_no_overwrite(tmp_path):
    entries, path = valid_entries(), tmp_path / "passwords.dpapi"
    assert create_credential_file(entries, path)["encrypted"]
    loaded = load_credentials(entries, path)
    encrypted = path.read_bytes()
    assert len(set(loaded.values())) == 28
    assert all(value.encode() not in encrypted for value in loaded.values())
    assert all(loaded[entry["username"]] == load_credentials(entries, path)[entry["username"]] for entry in entries)
    with pytest.raises(FileExistsError):
        create_credential_file(entries, path)
    assert path.read_bytes() == encrypted
    # DPAPI按password_env槽位保存，真实用户名确认后可沿用，不重新生成密码。
    renamed = deepcopy(entries)
    renamed[0]["username"] = "confirmed_actual_user"
    assert load_credentials(renamed, path)["confirmed_actual_user"] == loaded[entries[0]["username"]]


@pytest.mark.skipif(os.name != "nt", reason="Windows current-user DPAPI required")
def test_tampered_vault_and_wrong_slots_fail_closed(tmp_path):
    path, entries = tmp_path / "vault.dpapi", valid_entries()
    create_credential_file(entries, path)
    wrong = deepcopy(entries)
    wrong[0]["password_env"] = "WRONG_SLOT"
    with pytest.raises(ValueError, match="无法读取"):
        load_credentials(wrong, path)
    content = path.read_bytes()
    path.write_bytes(content[:-1] + bytes([content[-1] ^ 1]))
    with pytest.raises(ValueError, match="无法读取"):
        load_credentials(entries, path)


def test_credential_file_rejects_git_repository(tmp_path):
    (tmp_path / ".git").mkdir()
    with pytest.raises(ValueError, match="仓库之外"):
        external_path(tmp_path / "nested" / "vault.dpapi")


@pytest.mark.parametrize("problem", ["count", "duplicate_name", "role", "duplicate_id", "caregiver", "org", "elder"])
def test_b3_contract_rejects_invalid_identity_before_transaction(problem):
    entries = valid_entries()
    if problem == "count":
        entries.pop()
    elif problem == "duplicate_name":
        entries[1]["username"] = entries[0]["username"].upper()
    elif problem == "role":
        entries[0]["expected"]["role_code"] = "ELDER"
    elif problem == "duplicate_id":
        entries[1]["expected"]["user_id"] = 1
    elif problem == "caregiver":
        entries[1]["expected"]["caregiver_id"] = 1
    elif problem == "org":
        entries[25]["expected"]["org_id"] = 301
    else:
        entries[27]["expected"]["elder_id"] = 502
    with pytest.raises(ValueError):
        accounts.apply_b3_credentials(None, Principal(1, "admin", "SYS_ADMIN"), entries,
                                      {e["username"]: "UnitOnlyPassword!" + str(i) for i, e in enumerate(entries)})


class MemoryTransaction:
    """仅测试调用方工作单元的提交/回滚协议，不模拟SQL锁或服务器事务。"""
    def __init__(self, rows, *, total=28, fail_flush=False):
        self.rows, self.total, self.fail_flush = rows, total, fail_flush
        self.committed = self.rolled_back = False

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    @contextmanager
    def begin(self):
        snapshot = [deepcopy(vars(row)) for row in self.rows]
        try:
            yield
        except Exception:
            for row, values in zip(self.rows, snapshot):
                vars(row).clear()
                vars(row).update(values)
            self.rolled_back = True
            raise
        else:
            self.committed = True

    def scalar(self, statement):
        return self.total if "count(" in str(statement).lower() else datetime(2026, 11, 23)

    def scalars(self, _statement):
        return self.rows

    def execute(self, statement):
        assert "BEGIN TRANSACTION" in str(statement)

    def flush(self):
        if self.fail_flush:
            raise RuntimeError("injected flush failure")


def memory_database(monkeypatch, *, total=28, fail_flush=False):
    user = table("sys_user", column("username"))
    user.username = user.c.username
    monkeypatch.setattr(accounts, "SysUser", user)
    entries = valid_entries()
    rows = [SimpleNamespace(username=entry["username"], **entry["expected"],
        password_hash=accounts.DEMO_HASH, password_salt=accounts.DEMO_SALT,
        pwd_update_time=None, updated_at=None, user_status="正常", login_fail_count=2,
        lock_until=None, real_name="隔离测试") for entry in entries]
    session = MemoryTransaction(rows, total=total, fail_flush=fail_flush)
    database = object.__new__(Database)
    database.session_factory = lambda: session
    values = generate_passwords(entries)
    credentials = {entry["username"]: values[entry["password_env"]] for entry in entries}
    return database, session, entries, credentials


def test_batch_updates_only_four_fields(monkeypatch):
    db, session, entries, credentials = memory_database(monkeypatch)
    before = [deepcopy(vars(row)) for row in session.rows]
    assert accounts.apply_b3_credentials(db, Principal(1, "admin", "SYS_ADMIN"), entries, credentials)["accounts"] == 28
    assert session.committed and not session.rolled_back
    allowed = {"password_hash", "password_salt", "pwd_update_time", "updated_at"}
    for row, old in zip(session.rows, before):
        assert {key for key in vars(row) if getattr(row, key) != old[key]} == allowed
        assert verify_password(credentials[row.username], row.password_hash, row.password_salt)


@pytest.mark.parametrize("failure", ["flush", "identity", "count"])
def test_batch_failure_rolls_back_entire_work_unit(monkeypatch, failure):
    db, session, entries, credentials = memory_database(monkeypatch, total=27 if failure == "count" else 28,
                                                       fail_flush=failure == "flush")
    if failure == "identity":
        entries[0]["expected"]["org_id"] = 999
    before = [deepcopy(vars(row)) for row in session.rows]
    with pytest.raises((RuntimeError, ValueError)):
        accounts.apply_b3_credentials(db, Principal(1, "admin", "SYS_ADMIN"), entries, credentials)
    assert session.rolled_back and not session.committed
    assert all(vars(row) == old for row, old in zip(session.rows, before))


@pytest.mark.parametrize("total", [0, 27, 29])
def test_database_total_must_be_exactly_28(monkeypatch, total):
    db, session, entries, credentials = memory_database(monkeypatch, total=total)
    with pytest.raises(ValueError, match="总数"):
        accounts.apply_b3_credentials(db, Principal(1, "admin", "SYS_ADMIN"), entries, credentials)
    assert session.rolled_back and not session.committed


def test_case_insensitive_duplicate_credentials_are_rejected():
    credentials = {f"unit{i}": "UnitOnlyPassword!" + str(i) for i in range(28)}
    credentials["UNIT0"] = credentials.pop("unit1")
    with pytest.raises(ValueError, match="用户名"):
        accounts.validate_credentials(credentials)


@pytest.mark.parametrize("duplicate", ["salt", "hash"])
def test_duplicate_prepared_values_rejected_before_database(monkeypatch, duplicate):
    calls = []
    def derive(_):
        calls.append(True)
        return ("same" if duplicate == "hash" else str(len(calls)),
                "same" if duplicate == "salt" else str(len(calls)))
    monkeypatch.setattr(accounts, "hash_password", derive)
    monkeypatch.setattr(accounts, "verify_password", lambda *_: True)
    credentials = {str(i): "UnitOnly!" + str(i) for i in range(28)}
    with pytest.raises(ValueError, match="重复"):
        accounts.secure_b3_accounts(None, Principal(1, "admin", "SYS_ADMIN"), credentials)


def test_apply_requires_explicit_test_database_authorization(monkeypatch):
    import sys
    monkeypatch.setattr(sys, "argv", ["accounts", "--manifest", "not-read.json", "--apply",
                        "--admin", "admin", "--expected-database", "Unconfirmed"])
    with pytest.raises(SystemExit) as exc:
        accounts.main()
    assert exc.value.code == 2


def login_memory_database(monkeypatch):
    """复用真实LoginService/SessionStore，只有SQL查询由内存测试双替代。"""
    from .security import login, verify_b3
    user = table("sys_user", column("username"), column("user_id"))
    user.username, user.user_id = user.c.username, user.c.user_id
    for module in (accounts, login, verify_b3):
        monkeypatch.setattr(module, "SysUser", user)
    entries = valid_entries()
    values = generate_passwords(entries)
    credentials = {entry["username"]: values[entry["password_env"]] for entry in entries}
    rows = []
    for entry in entries:
        digest, salt = hash_password(credentials[entry["username"]])
        rows.append(SimpleNamespace(username=entry["username"], **entry["expected"],
            password_hash=digest, password_salt=salt, user_status="正常", lock_until=None,
            login_fail_count=0, last_login_time=None, updated_at=None))
    by_name = {row.username: row for row in rows}
    by_id = {row.user_id: row for row in rows}
    class Session:
        def scalars(self, _):
            return rows
        def scalar(self, statement, params=None):
            if "SYSDATETIME" in str(statement):
                return datetime(2026, 11, 23)
            if params and "cg" in params:
                return 1
            values = statement.compile().params
            return by_name[values["username_1"]] if "username_1" in values else by_id[values["user_id_1"]]
    @contextmanager
    def session():
        yield Session()
    return SimpleNamespace(session=session), entries, credentials


@pytest.mark.parametrize("failure", [None, "login", "identity", "logout"])
def test_per_account_report_and_safe_failures(monkeypatch, failure):
    from dataclasses import replace
    from .security import login, session as session_module, verify_b3
    db, entries, credentials = login_memory_database(monkeypatch)
    first = entries[0]["username"]
    if failure == "login":
        original = login.LoginService.login
        def fail_login(self, name, password):
            if name == first:
                raise RuntimeError("sensitive-error-sentinel")
            return original(self, name, password)
        monkeypatch.setattr(login.LoginService, "login", fail_login)
    elif failure == "identity":
        original = session_module.SessionStore.resolve
        def wrong_identity(self, session, token):
            actor = original(self, session, token)
            return replace(actor, org_id=999) if actor.username == first else actor
        monkeypatch.setattr(session_module.SessionStore, "resolve", wrong_identity)
    elif failure == "logout":
        monkeypatch.setattr(session_module.SessionStore, "logout", lambda *_: None)
    report = verify_b3.verify_accounts(db, entries, credentials=credentials, detailed=True)
    assert len(report["results"]) == report["accounts"] == 28
    assert report["login_pass"] == (27 if failure == "login" else 28)
    assert report["login_fail"] == (1 if failure == "login" else 0)
    assert report["session_identity_fail"] == (1 if failure == "identity" else 0)
    assert report["session_identity_pass"] == (27 if failure in {"login", "identity"} else 28)
    assert report["logout_pass"] == (0 if failure == "logout" else 27 if failure == "login" else 28)
    assert report["failed_accounts"] == (28 if failure == "logout" else 1 if failure else 0)
    serialized = json.dumps(report)
    assert "sensitive-error-sentinel" not in serialized
    assert all(password not in serialized for password in credentials.values())
    assert all(key not in serialized for key in ("password_hash", "password_salt", "token"))


def test_wrong_password_preflight_does_not_attempt_login(monkeypatch):
    from .security import login, verify_b3
    db, entries, credentials = login_memory_database(monkeypatch)
    credentials[entries[0]["username"]] += "-wrong"
    monkeypatch.setattr(login.LoginService, "login", lambda *_: pytest.fail("预检失败不应登录"))
    with pytest.raises(ValueError, match="尚未执行登录"):
        verify_b3.verify_accounts(db, entries, credentials=credentials)


def test_maintenance_authentication_does_not_write_login_fields(monkeypatch):
    db, entries, credentials = login_memory_database(monkeypatch)
    admin = next(e for e in entries if e["expected"]["role_code"] == "SYS_ADMIN")
    actor = accounts.maintenance_actor(db, admin["username"], credentials[admin["username"]])
    assert actor.role_code == "SYS_ADMIN"
    with db.session() as session:
        row = session.scalar(accounts.select(accounts.SysUser).where(accounts.SysUser.username == admin["username"]))
    assert row.last_login_time is None and row.updated_at is None and row.login_fail_count == 0


def test_real_sql_failure_after_flush_rolls_back_all_28(database, monkeypatch):
    """待授权隔离SQL Server运行；从另一个会话确认已flush的28行仍整体回滚。"""
    from uuid import uuid4
    from sqlalchemy import select, delete
    from .models import SysUser, ElderProfile
    tag = "B3ROLLBACK:" + uuid4().hex[:12]
    names = [tag + str(i) for i in range(28)]
    try:
        with database.session() as session:
            elder_id = session.scalar(select(ElderProfile.elder_id).limit(1))
            for name in names:
                session.add(SysUser(username=name, real_name="隔离回滚测试", role_code="ELDER", elder_id=elder_id,
                    password_hash=accounts.DEMO_HASH, password_salt=accounts.DEMO_SALT))
        entries = [dict(username=name, password_env="ROLLBACK_SLOT_" + str(i)) for i, name in enumerate(names)]
        values = generate_passwords(entries)
        credentials = {entry["username"]: values[entry["password_env"]] for entry in entries}
        def fail_after_flush(*_):
            raise RuntimeError("injected post-flush failure")
        monkeypatch.setattr(accounts, "audit_b3_accounts", fail_after_flush)
        with pytest.raises(RuntimeError, match="post-flush"):
            with database.session() as session:
                accounts.secure_b3_accounts(session, Principal(1, "isolated_admin", "SYS_ADMIN"), credentials)
        with database.session() as session:
            rows = list(session.scalars(select(SysUser).where(SysUser.username.in_(names))))
            assert len(rows) == 28
            assert all(row.password_hash == accounts.DEMO_HASH and row.password_salt == accounts.DEMO_SALT
                       and row.pwd_update_time is None for row in rows)
    finally:
        # 仅清理本测试唯一标签创建的账号；该测试本轮不会执行。
        with database.session() as session:
            session.execute(delete(SysUser).where(SysUser.username.in_(names)))
