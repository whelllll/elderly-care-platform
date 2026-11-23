"""对已安全初始化的实际B3执行28账号登录/Session核验，不输出密码或令牌。"""
import argparse
from collections import Counter
import json

from sqlalchemy import select, text

from ..models import SysUser
from .accounts import (audit_b3_accounts, load_manifest, validate_entries,
                       configured_credentials, check_target_database, EXPECTED_ROLES)
from .password import verify_password

IDENTITY = ("user_id", "username", "role_code", "org_id", "elder_id", "caregiver_id")


def verify_accounts(database, entries, *, credentials=None, detailed=False):
    from .login import LoginService
    from .session import SessionStore
    validate_entries(entries, require_expected=True)
    from .accounts import validate_credentials
    configured = configured_credentials(entries) if credentials is None else credentials
    validate_credentials(configured)
    if set(configured) != {entry["username"] for entry in entries}:
        raise ValueError("凭据账号与验收清单不一致。")
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
    results = []
    for name in names:
        result = dict(username=name, role_code=bindings[name]["role_code"], login=False,
                      session_created=False, identity_correct=None, logout=False, failure_reasons=[])
        token, phase = None, "login_failed"
        try:
            token = store.login(name, credentials[name])
            result["login"] = result["session_created"] = True
            phase = "session_validation_failed"
            with database.session() as session:
                actor = store.resolve(session, token)
                if any(getattr(actor, key) != value for key, value in bindings[name].items()):
                    result["identity_correct"] = False
                    phase = "identity_mismatch"
                    raise ValueError("登录Session身份与账号绑定不一致。")
                result["identity_correct"] = True
                row = session.scalar(select(SysUser).where(SysUser.username == name))
                if row.login_fail_count != 0:
                    phase = "failure_counter_not_reset"
                    raise ValueError("登录成功后失败计数未清零。")
        except Exception:
            # 只记录固定错误码，不序列化可能含密码、SQL参数或令牌的底层异常。
            result["failure_reasons"].append(phase)
        finally:
            if token is not None:
                try:
                    from ..errors import AuthenticationError
                    store.logout(token)
                    with database.session() as session:
                        try:
                            store.resolve(session, token)
                        except AuthenticationError:
                            result["logout"] = True
                        else:
                            raise ValueError("退出后会话仍有效。")
                except Exception:
                    result["failure_reasons"].append("logout_failed")
        results.append(result)
    report = dict(accounts=len(results), login_pass=sum(row["login"] for row in results),
        login_fail=sum(not row["login"] for row in results),
        session_identity_pass=sum(row["identity_correct"] is True for row in results),
        session_identity_fail=sum(row["identity_correct"] is False for row in results),
        identity_not_checked=sum(row["identity_correct"] is None for row in results),
        logout_pass=sum(row["logout"] for row in results),
        failed_accounts=sum(bool(row["failure_reasons"]) for row in results), results=results)
    if detailed:
        return report
    if report["failed_accounts"]:
        raise ValueError("B3逐账号登录或Session验收失败；请使用脱敏明细报告。")
    return {key: report[key] for key in ("accounts", "login_pass", "session_identity_pass")}


def main():
    from ..db import Database
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--expected-database", required=True, help="显式确认的实际数据库名")
    parser.add_argument("--credential-file", help="仓库外的DPAPI凭据文件；省略时使用原环境变量方案")
    parser.add_argument("--report", help="脱敏JSON报告路径；仅创建新文件")
    args = parser.parse_args()
    entries = load_manifest(args.manifest, require_expected=True)
    configured = configured_credentials(entries, args.credential_file)
    from pathlib import Path
    report_path = Path(args.report).resolve() if args.report else None
    if report_path and report_path.exists():
        raise ValueError("报告文件已存在，请指定新路径。")
    db = Database()
    try:
        db.initialize()  # 使用正常启动门禁，不绕过B3安全核验。
        check_target_database(db, args.expected_database)
        try:
            report = verify_accounts(db, entries, credentials=configured, detailed=True)
        except Exception:
            report = dict(accounts=28, login_pass=0, login_fail=0, login_not_attempted=28,
                session_identity_pass=0, session_identity_fail=0, identity_not_checked=28,
                logout_pass=0, failed_accounts=28,
                results=[dict(username=entry["username"], role_code=entry["expected"]["role_code"],
                    login=False, session_created=False, identity_correct=None, logout=False,
                    failure_reasons=["preflight_failed_no_login_attempted"]) for entry in entries])
        serialized = json.dumps(report, ensure_ascii=False)
        if report_path:
            report_path.parent.mkdir(parents=True, exist_ok=True)
            with report_path.open("x", encoding="utf-8") as stream:
                stream.write(serialized + "\n")
        print(serialized)
        if report["failed_accounts"]:
            raise SystemExit(1)
    finally:
        db.close()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        raise SystemExit("B3验收未完成；请核对目标库、账号清单、凭据文件及启动配置。") from None
