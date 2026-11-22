"""可选服务端扩展点；方案A本轮不要求尚未确认的任务预分配。"""


def require_assignment(policy, session, actor, operation, target_id):
    if policy is None:
        return
    # policy由后端启动代码注入，不能由HTTP请求/前端参数指定。
    # 实现必须查询正式数据库并在无任务、分配他人、无法确认时抛出AccessDenied。
    policy.require_assigned(session, actor, operation, target_id)
