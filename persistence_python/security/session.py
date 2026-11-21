"""单进程会话：30分钟空闲、8小时绝对期限；每次请求重新验证数据库身份。"""
from dataclasses import dataclass, replace
import hashlib
import secrets
from threading import RLock
from time import monotonic

from ..errors import AuthenticationError
from ..permissions import Principal


@dataclass(frozen=True)
class SessionEntry:
    principal: Principal
    issued_at: float
    last_activity: float


class SessionStore:
    def __init__(self, login_service, ttl_seconds=1800, max_lifetime_seconds=28800, *, clock=None):
        if not 0 < ttl_seconds <= 1800 or not 0 < max_lifetime_seconds <= 28800:
            raise ValueError("空闲期限必须在0..1800秒内，最长有效期在0..28800秒内。")
        self.login_service = login_service
        self.ttl = ttl_seconds  # 保留旧参数接口，表示空闲期限。
        self.max_lifetime = max_lifetime_seconds
        self._clock = clock if clock is not None else lambda: monotonic()
        self._sessions = {}
        self._lock = RLock()

    @staticmethod
    def _digest(token):
        if not isinstance(token, str) or not token:
            raise AuthenticationError("登录会话已失效。")
        return hashlib.sha256(token.encode()).digest()

    def _expired(self, entry, now):
        return now - entry.last_activity >= self.ttl or now - entry.issued_at >= self.max_lifetime

    def login(self, username, password):
        actor = self.login_service.login(username, password)
        token = secrets.token_urlsafe(32)
        now = self._clock()
        with self._lock:
            self._sessions = {key: value for key, value in self._sessions.items() if not self._expired(value, now)}
            self._sessions[self._digest(token)] = SessionEntry(actor, now, now)
        return token

    def resolve(self, session, token):
        digest, now = self._digest(token), self._clock()
        with self._lock:
            entry = self._sessions.get(digest)
            if entry is None or self._expired(entry, now):
                self._sessions.pop(digest, None)
                raise AuthenticationError("登录会话已失效。")
        try:
            actor = self.login_service.actor_for_user(session, entry.principal.user_id)
            if actor.auth_version != entry.principal.auth_version:
                raise AuthenticationError("密码已修改，请重新登录。")
        except AuthenticationError:
            self.logout(token)
            raise
        with self._lock:
            current, now = self._sessions.get(digest), self._clock()
            if current is None or self._expired(current, now):
                self._sessions.pop(digest, None)
                raise AuthenticationError("登录会话已失效。")
            self._sessions[digest] = replace(current, principal=actor, last_activity=now)
        return actor

    def logout(self, token):
        with self._lock:
            self._sessions.pop(self._digest(token), None)
