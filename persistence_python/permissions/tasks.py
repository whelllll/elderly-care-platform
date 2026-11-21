"""任务分配扩展点：必须由服务端实现并查询经成员5确认的真实数据库依据。"""
from ..errors import AssignmentUnavailable


def require_assignment(policy, session, actor, operation, target_id):
    if policy is None:
        raise AssignmentUnavailable(
            "当前正式结构尚无经确认的个人任务分配依据；相关操作暂不可执行。")
    # policy由后端启动代码注入，不能由HTTP请求/前端参数指定。
    # 实现必须查询正式数据库并在无任务、分配他人、无法确认时抛出AccessDenied。
    policy.require_assigned(session, actor, operation, target_id)
