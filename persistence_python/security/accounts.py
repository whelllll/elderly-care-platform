"""B3现有28账号的显式凭据迁移/核验；不创建账号，不修改身份绑定，不输出密码。"""
import argparse
import base64
import json
import os
import re
from collections.abc import Mapping
from collections import Counter

from sqlalchemy import select, text, func

from ..models import SysUser
from ..permissions import require
from ..procedures import begin_sql_transaction
from .password import hash_password, verify_password
from ..permissions.roles import ROLES

DEMO_SALT = "Pxr9DkGQx1zOIQ3v+GuGEw=="
DEMO_HASH = "+9w2RfX2uizSge3rQEsIPCnsyMt/TQGEqGYrcYxX38M="


IDENTITY_FIELDS = {"user_id", "role_code", "org_id", "elder_id", "caregiver_id"}
EXPECTED_ROLES = Counter(CAREGIVER=20, SYS_ADMIN=1, COMMUNITY_ADMIN=1, STREET_SUPERVISOR=1,
                         CIVIL_SUPERVISOR=1, ORG_MANAGER=2, ELDER=1, FAMILY=1)


def validate_b3_contract(entries):
    validate_entries(entries, require_expected=True)
    identities = [entry["expected"] for entry in entries]
    if Counter(row["role_code"] for row in identities) != EXPECTED_ROLES:
        raise ValueError("B3角色组成必须为20护工、2机构负责人及其余6种角色各1。")
    if len({row["user_id"] for row in identities}) != 28:
        raise ValueError("B3身份清单存在重复user_id。")
    for row in identities:
        role = row["role_code"]
        if role == "CAREGIVER":
            valid = row["caregiver_id"] is not None and row["org_id"] is not None and row["elder_id"] is None
        elif role in {"ELDER", "FAMILY"}:
            valid = row["elder_id"] is not None and row["org_id"] is None and row["caregiver_id"] is None
        elif role in {"COMMUNITY_ADMIN", "ORG_MANAGER"}:
            valid = row["org_id"] is not None and row["elder_id"] is None and row["caregiver_id"] is None
        else:
            valid = all(row[key] is None for key in ("org_id", "elder_id", "caregiver_id"))
        if not valid:
            raise ValueError("B3角色身份绑定不完整。")
    if len({row["caregiver_id"] for row in identities if row["role_code"] == "CAREGIVER"}) != 20:
        raise ValueError("B3护工须绑定20个不同人员。")
    if len({row["org_id"] for row in identities if row["role_code"] == "ORG_MANAGER"}) != 2:
        raise ValueError("B3机构负责人须绑定两个不同机构。")
    if len({row["elder_id"] for row in identities if row["role_code"] in {"ELDER", "FAMILY"}}) != 1:
        raise ValueError("B3老人和家属必须绑定同一老人。")
    return entries


def validate_entries(entries, *, require_expected=False):
    if not isinstance(entries, list) or len(entries) != 28:
        raise ValueError("B3清单必须精确列出28个不同的实际username。")
    names, variables = set(), set()
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) - {"username", "password_env", "expected"}:
            raise ValueError("清单仅允许username、password_env、expected，不允许保存密码。")
        name, variable = entry.get("username"), entry.get("password_env")
        if not isinstance(name, str) or not name.strip() or name != name.strip() or len(name.encode("utf-16-le")) > 100:
            raise ValueError("username必须非空、不含首尾空白且不超过50个UTF-16字符。")
        if not isinstance(variable, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", variable) or variable.upper() == "B3_ADMIN_PASSWORD":
            raise ValueError("密码环境变量名无效或与维护管理员密码变量冲突。")
        if name.casefold() in names or variable.casefold() in variables:
            raise ValueError("B3用户名和密码环境变量名均须独立，不得重复。")
        names.add(name.casefold())
        variables.add(variable.casefold())
        expected = entry.get("expected")
        if expected is None and not require_expected:
            continue
        if not isinstance(expected, dict) or set(expected) != IDENTITY_FIELDS or expected.get("role_code") not in ROLES:
            raise ValueError("expected须填写实际user_id、role_code、org_id、elder_id、caregiver_id。")
        for key in IDENTITY_FIELDS - {"role_code"}:
            value = expected[key]
            if value is None and key != "user_id":
                continue
            if isinstance(value, bool) or not isinstance(value, int) or not 0 < value <= 2147483647:
                raise ValueError("expected身份ID须为实际正整数；无绑定字段填null。")
    return entries


def load_manifest(path, *, require_expected=False):
    with open(path, encoding="utf-8-sig") as stream:
        manifest = json.load(stream)
    if not isinstance(manifest, dict) or set(manifest) != {"accounts"}:
        raise ValueError("清单根对象仅允许accounts字段。")
    return validate_entries(manifest["accounts"], require_expected=require_expected)


def validate_credentials(credentials):
    if not isinstance(credentials, Mapping) or len(credentials) != 28:
        raise ValueError("必须一次提供28个实际账号的凭据。")
    seen, names = set(), set()
    for name, password in credentials.items():
        if not isinstance(name, str) or not name.strip() or not isinstance(password, str) or len(password) < 8:
            raise ValueError("账号名无效或密码不符合现有至少8字符的要求。")
        if name != name.strip() or name.casefold() in names:
            raise ValueError("B3用户名不能重复或包含首尾空白。")
        names.add(name.casefold())
        if password == "Admin@123":
            raise ValueError("B3禁止复用演示共享密码。")
        if password in seen:
            raise ValueError("B3每个账号必须使用独立密码，不得共享密码。")
        seen.add(password)


def configured_credentials(entries, credential_file=None):
    if credential_file:
        from .credentials import load_credentials
        return load_credentials(entries, credential_file)
    credentials = {entry["username"]: os.environ.get(entry["password_env"]) for entry in entries}
    validate_credentials(credentials)
    return credentials


def check_target_database(database, expected):
    with database.session() as session:
        actual = session.scalar(text("SELECT DB_NAME()"))
    if not expected or actual.casefold() != expected.casefold():
        raise ValueError("实际数据库与显式确认的目标库不一致；未执行账号登录或凭据更新。")


def audit_b3_accounts(session, usernames):
    names = list(usernames)
    if len(names) != 28 or len(set(names)) != 28:
        raise ValueError("B3必须核验28个不同账号。")
    rows = list(session.scalars(select(SysUser).where(SysUser.username.in_(names))))
    if len(rows) != 28:
        raise ValueError("清单中部分账号不存在；不自动补建或猜测身份。")
    salts, hashes = set(), set()
    for row in rows:
        try:
            salt = base64.b64decode(row.password_salt, validate=True)
            digest = base64.b64decode(row.password_hash, validate=True)
        except (ValueError, TypeError) as exc:
            raise ValueError("B3账号存在非法密码编码。") from exc
        if (len(salt) != 16 or len(digest) != 32 or row.password_salt == DEMO_SALT
                or row.password_hash == DEMO_HASH
                or verify_password("Admin@123", row.password_hash, row.password_salt)):
            raise ValueError("B3账号使用演示凭据或不符合16字节盐/32字节哈希格式。")
        salts.add(salt)
        hashes.add(digest)
    if len(salts) != 28 or len(hashes) != 28:
        raise ValueError("B3账号存在共享盐值或哈希。")
    return {"accounts": 28, "unique_salts": 28, "unique_hashes": 28}


def secure_b3_accounts(session, actor, credentials, *, expected_identities=None):
    require(actor, "account:manage")
    validate_credentials(credentials)
    prepared = {}
    for name, password in credentials.items():
        digest, salt = hash_password(password)
        if not verify_password(password, digest, salt):
            raise ValueError("密码派生验证失败。")
        prepared[name] = (digest, salt)
    if len({value[0] for value in prepared.values()}) != 28 or len({value[1] for value in prepared.values()}) != 28:
        raise ValueError("新凭据盐值或哈希重复；未修改任何账号。")
    rows = list(session.scalars(select(SysUser).where(SysUser.username.in_(prepared))
                .order_by(SysUser.username).with_hint(SysUser, "WITH (UPDLOCK, HOLDLOCK)", "mssql")
                .execution_options(populate_existing=True)))
    if len(rows) != 28:
        raise ValueError("清单中部分账号不存在；未修改任何账号。")
    if expected_identities is not None:
        if set(expected_identities) != set(credentials):
            raise ValueError("预期身份清单与凭据账号不一致。")
        for row in rows:
            expected = expected_identities[row.username]
            if set(expected) != IDENTITY_FIELDS or any(getattr(row, key) != expected[key] for key in IDENTITY_FIELDS):
                raise ValueError("实际账号与预期身份不一致；未修改任何凭据。")
    now = session.scalar(text("SELECT SYSDATETIME()"))
    for row in rows:
        row.password_hash, row.password_salt = prepared[row.username]
        row.pwd_update_time = row.updated_at = now
    session.flush()
    return audit_b3_accounts(session, prepared)


def apply_b3_credentials(database, actor, entries, credentials):
    """正式批量入口：完整B3契约及总数检查，与现有改密共用一个事务。"""
    require(actor, "account:manage")
    validate_b3_contract(entries)
    validate_credentials(credentials)
    if set(credentials) != {entry["username"] for entry in entries}:
        raise ValueError("凭据与B3账号清单不一致。")
    with database.session() as session:
        begin_sql_transaction(session)
        # HOLDLOCK保持范围锁到事务结束，阻止并发插入使总数在检查后变化。
        total = session.scalar(select(func.count()).select_from(SysUser)
                               .with_hint(SysUser, "WITH (UPDLOCK, HOLDLOCK)", "mssql"))
        if total != 28:
            raise ValueError("目标库sys_user总数必须恰好为28；未更新凭据。")
        return secure_b3_accounts(session, actor, credentials,
            expected_identities={entry["username"]: entry["expected"] for entry in entries})


def maintenance_actor(database, username, password):
    """维护身份只读认证；批量更新不额外改管理员登录时间或失败计数。"""
    from .login import LoginService
    from ..errors import AuthenticationError
    service = LoginService(database)
    with database.session() as session:
        obj = session.scalar(select(SysUser).where(SysUser.username == username))
        if (obj is None or obj.user_status != "正常" or obj.lock_until is not None
                or not verify_password(password, obj.password_hash, obj.password_salt)):
            raise AuthenticationError("维护账号不可用或认证失败。")
        actor = service.principal(obj)
        require(actor, "account:manage")
        return actor


def main():
    from ..db import Database

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, help="账号名及密码环境变量名的JSON清单，不含明文密码")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true", help="显式授权更新清单中的28个现有账号")
    mode.add_argument("--check-config", action="store_true", help="离线检查清单及28个密码环境变量，不连接数据库")
    parser.add_argument("--expected-database", help="--apply必须显式指定已确认的实际数据库名")
    parser.add_argument("--admin", help="执行维护的系统管理员username；其密码从B3_ADMIN_PASSWORD读取")
    parser.add_argument("--credential-file", help="仓库外的当前Windows用户DPAPI凭据文件")
    parser.add_argument("--authorize-test-update", action="store_true", help="仅在获授权的目标测试库执行更新")
    args = parser.parse_args()
    if args.apply and (not args.expected_database or not args.admin):
        parser.error("--apply需要--expected-database及--admin")
    if args.apply and not args.authorize_test_update:
        parser.error("--apply还需要--authorize-test-update，确认已取得目标测试库写入授权")
    entries = load_manifest(args.manifest, require_expected=args.apply or args.check_config)
    if args.apply or args.check_config:
        validate_b3_contract(entries)
    credentials = configured_credentials(entries, args.credential_file) if args.apply or args.check_config else None
    if args.check_config:
        print(json.dumps({"accounts": 28, "config_valid": True, "database_accessed": False}))
        return
    # 仅此显式维护入口可暂缓启动凭据核验，否则旧共享凭据将无法迁移。
    db = Database()
    try:
        db.initialize(validate_b3=False)
        if args.expected_database:
            check_target_database(db, args.expected_database)
        if args.apply:
            if not args.admin or not os.environ.get("B3_ADMIN_PASSWORD"):
                raise ValueError("--apply需要实际管理员账号和B3_ADMIN_PASSWORD。")
            actor = maintenance_actor(db, args.admin, os.environ["B3_ADMIN_PASSWORD"])
            report = apply_b3_credentials(db, actor, entries, credentials)
        else:
            with db.session() as session:
                report = audit_b3_accounts(session, [entry["username"] for entry in entries])
        print(json.dumps(report))
    finally:
        db.close()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        raise SystemExit("B3操作失败；未输出凭据。请核对授权、目标、账号清单及账号状态。") from None
