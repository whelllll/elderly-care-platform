"""登录失败计数单独提交，避免异常向外传播时回滚计数；账号更新使用行锁。"""
from datetime import timedelta
import hashlib
import secrets

from sqlalchemy import select, text

from ..errors import AuthenticationError
from ..models import SysUser
from ..permissions import DataScope, Principal, require
from ..permissions.roles import ROLES
from .password import hash_password, verify_password


class LoginService:
    def __init__(self, database, scopes=None, organization_names=None):
        self.database = database
        self.scopes = dict(scopes or {})  # 旧接口兼容；方案A不使用行政范围白名单。
        self.organization_names = dict(organization_names or {})  # 后端配置，键为username。
        self._dummy_hash, self._dummy_salt = hash_password(secrets.token_urlsafe(24))

    def principal(self, obj):
        if obj.role_code not in ROLES or obj.user_status != "正常":
            raise AuthenticationError("账号或密码错误，或账号当前不可用。")
        if obj.role_code in {"ELDER", "FAMILY"} and obj.elder_id is None:
            raise AuthenticationError("账号身份绑定不完整。")
        if obj.role_code == "CAREGIVER" and obj.caregiver_id is None:
            raise AuthenticationError("账号身份绑定不完整。")
        if obj.role_code in {"COMMUNITY_ADMIN", "ORG_MANAGER"} and obj.org_id is None:
            raise AuthenticationError("账号身份绑定不完整。")
        version = hashlib.sha256((obj.password_salt + ":" + obj.password_hash).encode()).hexdigest()
        return Principal(obj.user_id, obj.username, obj.role_code, obj.org_id, obj.elder_id,
                         obj.caregiver_id, self.scopes.get(obj.user_id, DataScope()),
                         auth_version=version, audit_org=self.organization_names.get(obj.username))

    def login(self, username, password):
        actor = None
        with self.database.session() as session:
            obj = session.scalar(select(SysUser).where(SysUser.username == username)
                                 .with_hint(SysUser, "WITH (UPDLOCK, HOLDLOCK)", "mssql"))
            now = session.scalar(text("SELECT SYSDATETIME()"))
            if obj is None:
                verify_password(password, self._dummy_hash, self._dummy_salt)
            else:
                if obj.user_status == "锁定" and obj.lock_until is not None and obj.lock_until <= now:
                    obj.user_status, obj.lock_until, obj.login_fail_count = "正常", None, 0
                if obj.user_status == "正常":
                    if verify_password(password, obj.password_hash, obj.password_salt):
                        obj.login_fail_count, obj.last_login_time = 0, now
                        actor = self.principal(obj)
                    else:
                        obj.login_fail_count = min(obj.login_fail_count + 1, 5)
                        if obj.login_fail_count == 5:
                            obj.user_status, obj.lock_until = "锁定", now + timedelta(minutes=30)
                    obj.updated_at = now
        if actor is None:
            raise AuthenticationError("账号或密码错误，或账号当前不可用。")
        return actor

    def actor_for_user(self, session, user_id):
        obj = session.scalar(select(SysUser).where(SysUser.user_id == user_id)
                             .execution_options(populate_existing=True))
        if obj is None:
            raise AuthenticationError("登录会话已失效。")
        return self.principal(obj)

    def create_account(self, session, actor, *, username, password, real_name, role_code,
                       org_id=None, elder_id=None, caregiver_id=None):
        require(actor, "account:manage")
        if role_code not in ROLES:
            raise ValueError("未知角色。")
        digest, salt = hash_password(password)
        obj = SysUser(username=username, password_hash=digest, password_salt=salt, real_name=real_name,
                      role_code=role_code, org_id=org_id, elder_id=elder_id, caregiver_id=caregiver_id)
        session.add(obj)
        session.flush()  # 正式角色/身份CHECK及外键继续生效。
        return obj.user_id

    def set_account_status(self, session, actor, user_id, *, enabled):
        require(actor, "account:manage")
        obj = session.scalar(select(SysUser).where(SysUser.user_id == user_id)
                             .with_hint(SysUser, "WITH (UPDLOCK, HOLDLOCK)", "mssql"))
        if obj is None:
            raise ValueError("账号不存在。")
        obj.user_status, obj.lock_until, obj.login_fail_count = ("正常" if enabled else "停用"), None, 0
        obj.updated_at = session.scalar(text("SELECT SYSDATETIME()"))
        session.flush()

    @staticmethod
    def _set_password(session, obj, password):
        obj.password_hash, obj.password_salt = hash_password(password)
        obj.pwd_update_time = obj.updated_at = session.scalar(text("SELECT SYSDATETIME()"))
        session.flush()

    def change_password(self, session, actor, current_password, new_password):
        require(actor, "account:password")
        obj = session.scalar(select(SysUser).where(SysUser.user_id == actor.user_id)
                             .with_hint(SysUser, "WITH (UPDLOCK, HOLDLOCK)", "mssql")
                             .execution_options(populate_existing=True))
        if obj is None or obj.user_status != "正常" or not verify_password(current_password, obj.password_hash, obj.password_salt):
            raise AuthenticationError("账号或密码错误，或账号当前不可用。")
        self._set_password(session, obj, new_password)

    def reset_password(self, session, actor, user_id, new_password):
        require(actor, "account:manage")
        obj = session.scalar(select(SysUser).where(SysUser.user_id == user_id)
                             .with_hint(SysUser, "WITH (UPDLOCK, HOLDLOCK)", "mssql"))
        if obj is None:
            raise ValueError("账号不存在。")
        self._set_password(session, obj, new_password)
