"""成员3：护工/证书/排班CRUD，签到签退及工时审核。"""
from sqlalchemy import select, text

from .base_dao import BaseDAO
from .errors import AccessDenied
from .models import DispatchRecord, WorkRecord
from .permissions import require
from .procedures import call_procedure, lock_order_actions


class Member3DAO:
    caregivers = BaseDAO("caregiver")
    certificates = BaseDAO("caregiver_certificate")
    schedules = BaseDAO("caregiver_schedule")
    work_records = BaseDAO("work_record")

    def _dispatch(self, session, actor, dispatch_id):
        lock_order_actions(session)
        obj = BaseDAO("dispatch_record").required(session, dispatch_id, actor)
        session.scalar(select(DispatchRecord).where(DispatchRecord.dispatch_id == dispatch_id)
                       .with_hint(DispatchRecord, "WITH (UPDLOCK, HOLDLOCK)", "mssql")
                       .execution_options(populate_existing=True))
        if obj.caregiver_id != actor.caregiver_id or obj.dispatch_status != "已接单":
            raise AccessDenied("签到签退必须使用自己的已接单记录。")
        return obj

    def check_in(self, session, actor, dispatch_id, location):
        require(actor, "work:checkin")
        dispatch = self._dispatch(session, actor, dispatch_id)
        order = BaseDAO("service_order").required(session, dispatch.order_id, actor)
        if order.order_status != "待服务":
            raise ValueError("签到要求订单为待服务，且派单已接单。")
        if session.scalar(select(WorkRecord.work_id).where(WorkRecord.dispatch_id == dispatch_id)) is not None:
            raise ValueError("该派单已签到。")
        fence = call_procedure(session, "usp_M2_CheckFence", OrderID=dispatch.order_id, Location=location).outputs
        obj = WorkRecord(schedule_id=dispatch.schedule_id, dispatch_id=dispatch_id,
                         check_in_time=session.scalar(text("SELECT SYSDATETIME()")),
                         check_in_location=location, fence_result=fence["FenceResult"], review_status="待审核")
        session.add(obj)
        session.flush()
        return obj

    def check_out(self, session, actor, dispatch_id, location):
        require(actor, "work:checkout")
        dispatch = self._dispatch(session, actor, dispatch_id)
        order = BaseDAO("service_order").required(session, dispatch.order_id, actor)
        if order.order_status != "服务中":
            raise ValueError("签退要求订单处于服务中，请先执行START。")
        obj = session.scalar(select(WorkRecord).where(WorkRecord.dispatch_id == dispatch_id))
        now = session.scalar(text("SELECT SYSDATETIME()"))
        if obj is None or obj.check_out_time is not None or now <= obj.check_in_time:
            raise ValueError("必须先签到且只能签退一次，签退时间必须晚于签到。")
        obj.check_out_time, obj.check_out_location = now, location
        session.flush()
        return obj

    def review(self, session, actor, work_id, *, approved, effective_minutes=None, note=None):
        require(actor, "work:review")
        lock_order_actions(session)
        obj = self.work_records.required(session, work_id, actor)
        if approved and (obj.check_out_time is None or isinstance(effective_minutes, bool)
                         or not isinstance(effective_minutes, int) or effective_minutes < 0):
            raise ValueError("通过审核必须有签退时间及非负整数有效分钟数。")
        obj.review_status, obj.review_note = ("通过" if approved else "驳回"), note
        obj.effective_minutes = effective_minutes if approved else None
        session.flush()  # 正式CHECK继续校验时长上限及异常围栏的审核说明。
        return obj
