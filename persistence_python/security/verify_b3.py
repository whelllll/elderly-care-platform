"""对已安全初始化的实际B3执行28账号登录/Session核验，不输出密码或令牌。"""
import argparse
from collections import Counter
import json

from sqlalchemy import select, text

from ..models import SysUser
from .accounts import (audit_b3_accounts, load_manifest, validate_entries,
                       configured_credentials, check_target_database)
from .password import verify_password

EXPECTED_ROLES = Counter(CAREGIVER=20, SYS_ADMIN=1, COMMUNITY_ADMIN=1, STREET_SUPERVISOR=1,
                         CIVIL_SUPERVISOR=1, ORG_MANAGER=2, ELDER=1, FAMILY=1)
IDENTITY = ("user_id", "username", "role_code", "org_id", "elder_id", "caregiver_id")


def verify_accounts(database, entries):
    from .login import LoginService
    from .session import SessionStore
    validate_entries(entries, require_expected=True)
    configured = configured_credentials(entries)
    names = [entry["username"] for entry in entries]
    with database.session() as session:
        audit_b3_accounts(session, names)
        rows = list(session.scalars(select(SysUser).where(SysUser.username.in_(names))))
        if Counter(row.role_code for row in rows) != EXPECTED_ROLES:
            raise ValueError("B3角色数量不符。")
        bindings = {row.username: {key: getattr(row, key) for key in IDENTITY} for row in rows}
        elders = {row.elder_id for row in rows if row.role_code in {"ELDER", "FAMILY"}}
        orgs = {row.org_id for row in rows if row.role_code == "ORG_MANAGER"}
        if None in elders or len(elders) != 1 or None in orgs or len(orgs) != 2:
            raise ValueError("B3老人/家属或机构负责人绑定不符合脚本契约。")
        caregivers = [row.caregiver_id for row in rows if row.role_code == "CAREGIVER"]
        if None in caregivers or len(set(caregivers)) != 20:
            raise ValueError("B3护工绑定须为20个不同实际护工。")
        for row in rows:
            if row.role_code == "CAREGIVER" and not session.scalar(text("""SELECT COUNT(*) FROM dbo.caregiver
                    WHERE caregiver_id=:cg AND org_id=:org AND employment_status=N'在岗'"""),
                    {"cg": row.caregiver_id, "org": row.org_id}):
                raise ValueError("护工身份与机构绑定无效。")
            if row.role_code in {"SYS_ADMIN", "STREET_SUPERVISOR", "CIVIL_SUPERVISOR"} and any(
                    getattr(row, key) is not None for key in ("org_id", "elder_id", "caregiver_id")):
                raise ValueError("监管/系统账号不应绑定机构或个人。")
        # 先只读验证全部密码，错误配置不会通过试登录增加失败计数或锁定正式账号。
        by_name = {row.username: row for row in rows}
        credentials = {}
        for entry in entries:
            row = by_name[entry["username"]]
            password = configured[entry["username"]]
            if row.user_status != "正常" or row.lock_until is not None or not verify_password(password, row.password_hash, row.password_salt):
                raise ValueError("账号未就绪或密码环境变量不匹配；尚未执行登录。")
            expected = entry.get("expected", {})
            if not expected or set(expected) != set(IDENTITY) - {"username"}:
                raise ValueError("清单expected须包含经人工核对的user_id、role_code、org_id、elder_id、caregiver_id。")
            if any(getattr(row, key) != value for key, value in expected.items()):
                raise ValueError("实际账号与清单预期身份不符。")
            credentials[row.username] = password
    store = SessionStore(LoginService(database))
    count = 0
    for name in names:
        token = store.login(name, credentials[name])
        try:
            with database.session() as session:
                actor = store.resolve(session, token)
                if any(getattr(actor, key) != value for key, value in bindings[name].items()):
                    raise ValueError("登录Session身份与账号绑定不一致。")
                row = session.scalar(select(SysUser).where(SysUser.username == name))
                if row.login_fail_count != 0:
                    raise ValueError("登录成功后失败计数未清零。")
            count += 1
        finally:
            store.logout(token)
    return {"accounts": count, "login_pass": count, "session_identity_pass": count}


def main():
    from ..db import Database
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--expected-database", required=True, help="显式确认的实际数据库名")
    args = parser.parse_args()
    entries = load_manifest(args.manifest, require_expected=True)
    db = Database().initialize()  # 使用正常启动门禁，不绕过B3安全核验。
    try:
        check_target_database(db, args.expected_database)
        print(json.dumps(verify_accounts(db, entries)))
    finally:
        db.close()


if __name__ == "__main__":
    main()
