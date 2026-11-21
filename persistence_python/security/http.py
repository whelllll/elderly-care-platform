"""供现有WSGI后端挂接的认证/异常适配器；不创建新的Web应用或监听端口。"""
import json

from ..errors import AccessDenied, AuthenticationError


class AuthenticationMiddleware:
    def __init__(self, app, database, sessions, *, public_paths=()):
        self.app, self.database, self.sessions = app, database, sessions
        self.public_paths = frozenset(public_paths)

    def __call__(self, environ, start_response):
        if environ.get("PATH_INFO", "") in self.public_paths:
            return self.app(environ, start_response)
        try:
            scheme, _, token = environ.get("HTTP_AUTHORIZATION", "").partition(" ")
            if scheme.lower() != "bearer" or not token.strip():
                raise AuthenticationError("需要有效登录会话。")
            captured = {}

            def capture(status, headers, exc_info=None):
                captured.update(status=status, headers=headers, exc_info=exc_info)
                # 支持WSGI旧式write()，在事务提交前收集响应，失败不先发送200。
                return body.append

            body = []
            with self.database.session() as session:
                environ["eldercare.actor"] = self.sessions.resolve(session, token.strip())
                environ["eldercare.session"] = session
                response = self.app(environ, capture)
                try:
                    body.extend(response)
                finally:
                    if hasattr(response, "close"):
                        response.close()
            start_response(captured["status"], captured["headers"], captured["exc_info"])
            return body
        except (AuthenticationError, AccessDenied) as exc:
            status = "401 Unauthorized" if exc.status_code == 401 else "403 Forbidden"
            body = json.dumps({"error": str(exc)}, ensure_ascii=False).encode("utf-8")
            headers = [("Content-Type", "application/json; charset=utf-8"), ("Content-Length", str(len(body)))]
            if exc.status_code == 401:
                headers.append(("WWW-Authenticate", "Bearer"))
            start_response(status, headers)
            return [body]
