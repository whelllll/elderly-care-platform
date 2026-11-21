class AccessDenied(PermissionError):
    """角色或数据范围不允许访问；不区分不存在与越权对象。"""
    status_code = 403


class AuthenticationError(ValueError):
    """统一的登录失败错误，避免泄露账号是否存在。"""
    status_code = 401


class AssignmentUnavailable(AccessDenied):
    """正式数据库尚无经确认的个人任务分配依据；禁止将操作留痕当预分配。"""
