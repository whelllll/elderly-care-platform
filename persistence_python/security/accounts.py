"""B3现有28账号的显式凭据迁移/核验；不创建账号，不修改身份绑定，不输出密码。"""
import argparse
import base64
import json
import os

from sqlalchemy import select, text

from ..models import SysUser
from ..permissions import require
from .password import hash_password, verify_password

DEMO_SALT = "Pxr9DkGQx1zOIQ3v+GuGEw=="
DEMO_HASH = "+9w2RfX2uizSge3rQEsIPCnsyMt/TQGEqGYrcYxX38M="


def load_manifest(path):
    with open(path, encoding="utf-8-sig") as stream:
        entries = json.load(stream)["accounts"]
    if len(entries) != 28 or len({entry["username"] for entry in entries}) != 28:
        raise ValueError("B3清单必须精确列出28个不同的实际username。")
    return entries


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
        salts.add(row.password_salt)
        hashes.add(row.password_hash)
    if len(salts) != 28 or len(hashes) != 28:
        raise ValueError("B3账号存在共享盐值或哈希。")
    return {"accounts": 28, "unique_salts": 28, "unique_hashes": 28}


def secure_b3_accounts(session, actor, credentials):
    require(actor, "account:manage")
    if len(credentials) != 28:
        raise ValueError("必须一次提供28个实际账号的凭据。")
    prepared = {}
    for name, password in credentials.items():
        if password == "Admin@123":
            raise ValueError("B3禁止复用演示共享密码。")
        digest, salt = hash_password(password)
        if not verify_password(password, digest, salt):
            raise ValueError("密码派生验证失败。")
        prepared[name] = (digest, salt)
    rows = list(session.scalars(select(SysUser).where(SysUser.username.in_(prepared))
                .order_by(SysUser.username).with_hint(SysUser, "WITH (UPDLOCK, HOLDLOCK)", "mssql")))
    if len(rows) != 28:
        raise ValueError("清单中部分账号不存在；未修改任何账号。")
    now = session.scalar(text("SELECT SYSDATETIME()"))
    for row in rows:
        row.password_hash, row.password_salt = prepared[row.username]
        row.pwd_update_time = row.updated_at = now
    session.flush()
    return audit_b3_accounts(session, prepared)


def main():
    from ..db import Database
    from .login import LoginService

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, help="账号名及密码环境变量名的JSON清单，不含明文密码")
    parser.add_argument("--apply", action="store_true", help="显式授权更新清单中的28个现有账号")
    parser.add_argument("--admin", help="执行维护的系统管理员username；其密码从B3_ADMIN_PASSWORD读取")
    args = parser.parse_args()
    entries = load_manifest(args.manifest)
    # 仅此显式维护入口可暂缓启动凭据核验，否则旧共享凭据将无法迁移。
    db = Database().initialize(validate_b3=False)
    try:
        if args.apply:
            if not args.admin or not os.environ.get("B3_ADMIN_PASSWORD"):
                raise ValueError("--apply需要实际管理员账号和B3_ADMIN_PASSWORD。")
            actor = LoginService(db).login(args.admin, os.environ["B3_ADMIN_PASSWORD"])
            credentials = {}
            for entry in entries:
                value = os.environ.get(entry["password_env"])
                if not value:
                    raise ValueError("部分密码环境变量未设置；未执行凭据更新。")
                credentials[entry["username"]] = value
            with db.session() as session:
                report = secure_b3_accounts(session, actor, credentials)
        else:
            with db.session() as session:
                report = audit_b3_accounts(session, [entry["username"] for entry in entries])
        print(json.dumps(report))
    finally:
        db.close()


if __name__ == "__main__":
    main()
