from ..errors import AccessDenied, AuthenticationError
from .roles import BUSINESS, PUBLIC_READ, READ, ROLES, WRITE


def require(actor, action):
    if actor is None:
        raise AuthenticationError("需要有效登录身份。")
    if actor.role_code not in ROLES:
        raise AccessDenied("未知角色。")
    binding = {"ELDER": "elder_id", "FAMILY": "elder_id", "CAREGIVER": "caregiver_id",
               "ORG_MANAGER": "org_id"}.get(actor.role_code)
    if binding:
        value = getattr(actor, binding, None)
        if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
            raise AccessDenied("个人或机构身份绑定不完整。")
    if action in BUSINESS and actor.role_code in BUSINESS[action]:
        return
    resource, _, operation = action.partition(":")
    if operation == "read" and (resource in PUBLIC_READ or actor.role_code == "SYS_ADMIN"
                                or resource in READ.get(actor.role_code, ())):
        return
    if operation == "write" and resource in WRITE.get(actor.role_code, ()):
        return
    raise AccessDenied("该角色不允许执行此操作。")
