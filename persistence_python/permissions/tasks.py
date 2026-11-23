"""补贴审核归属组件；审核入口在申请行锁内强制检查节点与任务归属。"""
from sqlalchemy import and_, or_

from ..errors import AccessDenied
from .guards import require

AUDIT_STAGES = {"COMMUNITY_ADMIN": "待社区初审", "STREET_SUPERVISOR": "街道复审中"}


def audit_stage(actor):
    require(actor, "subsidy:audit")
    stage = AUDIT_STAGES.get(actor.role_code)
    if stage is None:
        raise AccessDenied("该角色没有补贴审核待办权限。")
    require(actor, "subsidy:community_audit" if actor.role_code == "COMMUNITY_ADMIN"
            else "subsidy:street_audit")
    return stage


def audit_task_filter(columns, actor):
    return and_(columns.audit_status == audit_stage(actor),
                or_(columns.current_auditor_id.is_(None), columns.current_auditor_id == actor.user_id))


def require_audit_task(actor, application):
    """只检查当前快照；写操作调用方必须先持有申请行锁并在同一事务内写入。"""
    if application.audit_status != audit_stage(actor):
        raise AccessDenied("该角色不能处理当前审核节点。")
    if application.current_auditor_id is not None and application.current_auditor_id != actor.user_id:
        raise AccessDenied("审核任务已指派给其他人员。")


def require_assignment(policy, session, actor, operation, target_id):
    if policy is None:
        return
    # policy由后端启动代码注入，不能由HTTP请求/前端参数指定。
    # 保留旧补贴审核扩展接口；不能由调用方策略替代require_audit_task的固定规则。
    policy.require_assigned(session, actor, operation, target_id)
