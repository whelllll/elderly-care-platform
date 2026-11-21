"""验证适配器协议，不将其当作尚不存在的HTTP应用端到端测试。"""
from contextlib import contextmanager
from types import SimpleNamespace

import pytest

from .errors import AuthenticationError
from .permissions import Principal, require
from .security.http import AuthenticationMiddleware


@pytest.mark.parametrize("authorization,action,status", [
    ("", "order:dispatch", "401"),
    ("Basic xyz", "order:dispatch", "401"),
    ("Bearer expired", "order:dispatch", "401"),
    ("Bearer good", "order:dispatch", "403"),
    ("Bearer good", "service_item:read", "200"),
])
def test_http_authentication_status_and_server_identity(authorization, action, status):
    actor = Principal(1, "reader", "ELDER", elder_id=1)
    outcome = []

    @contextmanager
    def session():
        try:
            yield object()
            outcome.append("commit")
        except Exception:
            outcome.append("rollback")
            raise

    def resolve(session, token):
        if token != "good":
            raise AuthenticationError("expired")
        return actor

    def app(environ, start_response):
        assert environ["eldercare.actor"] is actor
        require(environ["eldercare.actor"], action)
        start_response("200 OK", [("Content-Type", "text/plain")])
        return [b"ok"]

    middleware = AuthenticationMiddleware(app, SimpleNamespace(session=session), SimpleNamespace(resolve=resolve))
    response = {}
    body = b"".join(middleware({"PATH_INFO": "/protected", "HTTP_AUTHORIZATION": authorization,
                                "HTTP_X_ROLE_CODE": "SYS_ADMIN", "QUERY_STRING": "user_id=999"},
                               lambda value, headers, *args: response.update(status=value, headers=headers)))
    assert response["status"].startswith(status)
    assert body
    if status == "200":
        assert outcome == ["commit"]
    elif authorization.startswith("Bearer"):
        assert outcome == ["rollback"]
