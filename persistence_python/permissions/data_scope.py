"""每次在SQL查询内过滤范围，避免主键查询、分页或身份映射缓存绕过范围。"""
from sqlalchemy import and_, false, or_, select, true

from ..models import (Caregiver, CaregiverSchedule, CarePlan, DispatchRecord, ElderProfile,
                      ServiceOrder, SubsidyApplication, SubsidyApplicationItem, SysUser)
from .roles import REGIONAL_ROLES


def caregiver_ids(actor):
    c = Caregiver.__table__.c
    if actor.role_code in REGIONAL_ROLES or actor.role_code == "SYS_ADMIN":
        condition = true()
    elif actor.role_code == "CAREGIVER":
        condition = c.caregiver_id == actor.caregiver_id if actor.caregiver_id else false()
    elif actor.role_code == "ORG_MANAGER":
        condition = c.org_id == actor.org_id if actor.org_id else false()
    else:
        condition = or_(c.org_id.in_(actor.scope.org_ids), c.service_area.in_(actor.scope.communities))
    return select(c.caregiver_id).where(condition)


def elder_ids(actor):
    e = ElderProfile.__table__.c
    if actor.role_code in {"ELDER", "FAMILY"}:
        # 以现有sys_user绑定为最终依据，同时匹配服务端身份快照，拒绝篡改/过时绑定。
        return select(SysUser.elder_id).where(SysUser.user_id == actor.user_id,
            SysUser.role_code == actor.role_code, SysUser.user_status == "正常",
            SysUser.elder_id == actor.elder_id) if actor.elder_id else select(e.elder_id).where(false())
    elif actor.role_code in REGIONAL_ROLES or actor.role_code == "SYS_ADMIN":
        condition = true()
    elif actor.role_code in {"CAREGIVER", "ORG_MANAGER"}:
        o, d = ServiceOrder.__table__.c, DispatchRecord.__table__.c
        return select(o.elder_id).join(DispatchRecord.__table__, d.order_id == o.order_id).where(
            d.caregiver_id.in_(caregiver_ids(actor)), d.dispatch_status.in_(("待接单", "已接单")))
    else:
        condition = e.community_name.in_(actor.scope.communities)
    return select(e.elder_id).where(condition)


def predicate(table_name, c, actor):
    # 方案A仅取消行政区域过滤；能否读/写仍必须先通过require()的角色权限检查。
    if actor.role_code == "SYS_ADMIN" or actor.role_code in REGIONAL_ROLES or table_name == "service_item":
        return true()
    if table_name == "subsidy_policy":
        return true()
    if table_name == "sys_user":
        return c.user_id == actor.user_id
    if table_name == "elder_profile":
        return c.elder_id.in_(elder_ids(actor))
    if table_name == "service_order" and actor.role_code in {"CAREGIVER", "ORG_MANAGER"}:
        return c.order_id.in_(select(DispatchRecord.order_id).where(
            DispatchRecord.caregiver_id.in_(caregiver_ids(actor))))
    if table_name == "subsidy_application" and actor.role_code == "ORG_MANAGER":
        orders = select(DispatchRecord.order_id).where(DispatchRecord.caregiver_id.in_(caregiver_ids(actor)))
        return c.application_id.in_(select(SubsidyApplicationItem.application_id).where(
            SubsidyApplicationItem.order_id.in_(orders)))
    if table_name == "service_org":
        return c.org_id.in_(({actor.org_id} if actor.role_code == "ORG_MANAGER" and actor.org_id
                             else actor.scope.org_ids))
    if table_name == "caregiver":
        if actor.role_code == "ORG_MANAGER":
            return c.org_id == actor.org_id if actor.org_id else false()
        return c.caregiver_id.in_(caregiver_ids(actor))
    if table_name in {"caregiver_certificate", "caregiver_schedule"}:
        return c.caregiver_id.in_(caregiver_ids(actor))
    if table_name == "work_record":
        return c.schedule_id.in_(select(CaregiverSchedule.schedule_id).where(
            CaregiverSchedule.caregiver_id.in_(caregiver_ids(actor))))
    if table_name == "dispatch_record":
        if actor.role_code in {"CAREGIVER", "ORG_MANAGER"}:
            return c.caregiver_id.in_(caregiver_ids(actor))
        return c.order_id.in_(select(ServiceOrder.order_id).where(ServiceOrder.elder_id.in_(elder_ids(actor))))
    if table_name == "care_plan_item":
        return c.plan_id.in_(select(CarePlan.plan_id).where(CarePlan.elder_id.in_(elder_ids(actor))))
    if table_name == "subsidy_application_item" or table_name == "subsidy_audit_log":
        if actor.role_code == "ORG_MANAGER":
            orders = select(DispatchRecord.order_id).where(DispatchRecord.caregiver_id.in_(caregiver_ids(actor)))
            applications = select(SubsidyApplicationItem.application_id).where(SubsidyApplicationItem.order_id.in_(orders))
            return and_(c.application_id.in_(applications), c.order_id.in_(orders)) if table_name == "subsidy_application_item" else c.application_id.in_(applications)
        return c.application_id.in_(select(SubsidyApplication.application_id).where(
            SubsidyApplication.elder_id.in_(elder_ids(actor))))
    if table_name == "quality_inspection":
        if actor.role_code == "ORG_MANAGER":
            return or_(c.caregiver_id.in_(caregiver_ids(actor)), c.order_id.in_(
                select(DispatchRecord.order_id).where(DispatchRecord.caregiver_id.in_(caregiver_ids(actor)))))
        return or_(c.caregiver_id.in_(caregiver_ids(actor)),
                   c.order_id.in_(select(ServiceOrder.order_id).where(ServiceOrder.elder_id.in_(elder_ids(actor)))))
    if table_name == "rectification":
        if actor.role_code == "CAREGIVER":
            return or_(c.caregiver_id == actor.caregiver_id,
                       and_(c.rectify_scope == "机构", c.caregiver_id.is_(None),
                            c.org_id.in_(select(Caregiver.org_id).where(Caregiver.caregiver_id == actor.caregiver_id))))
        return c.org_id.in_(({actor.org_id} if actor.role_code == "ORG_MANAGER" and actor.org_id
                             else actor.scope.org_ids))
    if "elder_id" in c:
        return c.elder_id.in_(elder_ids(actor))
    return false()
