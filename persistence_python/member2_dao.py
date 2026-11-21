"""成员2：状态流转一律经过正式存储过程，复用整改共同锁及原子校验。"""
from sqlalchemy import text

from .base_dao import BaseDAO
from .errors import AccessDenied
from .permissions import require
from .procedures import call_procedure


class Member2DAO:
    items = BaseDAO("service_item")
    orders = BaseDAO("service_order")
    dispatches = BaseDAO("dispatch_record")

    def create_order(self, session, actor, *, elder_id, service_id, appointment_time, service_address,
                     latitude=None, longitude=None, radius_m=None, remark=None, order_channel="电话"):
        require(actor, "order:create")
        BaseDAO("elder_profile").required(session, elder_id, actor)
        self.items.required(session, service_id, actor)
        return call_procedure(session, "usp_M2_CreateOrder", ElderID=elder_id, ServiceID=service_id,
                              AppointmentTime=appointment_time, ServiceAddress=service_address,
                              Latitude=latitude, Longitude=longitude, RadiusM=radius_m, Remark=remark,
                              OrderChannel=order_channel).outputs["OrderID"]

    def action(self, session, actor, order_id, action, *, caregiver_id=None, dispatch_id=None,
               reason=None, confirmed=False, service_record=None):
        action = action.upper()
        require(actor, "order:" + action.lower())
        self.orders.required(session, order_id, actor)
        if action in {"DISPATCH", "REASSIGN"}:
            BaseDAO("caregiver").required(session, caregiver_id, actor)
        if action in {"REASSIGN", "ACCEPT", "REJECT", "WITHDRAW", "START", "COMPLETE"}:
            dispatch = self.dispatches.required(session, dispatch_id, actor)
            if dispatch.order_id != order_id:
                raise AccessDenied("派单不属于该订单。")
            if actor.role_code == "CAREGIVER" and dispatch.caregiver_id != actor.caregiver_id:
                raise AccessDenied("只能操作分配给自己的派单。")
        return call_procedure(session, "usp_M2_OrderAction", OrderID=order_id, Action=action,
                              CaregiverID=caregiver_id, DispatchID=dispatch_id, Reason=reason,
                              Confirmed=confirmed, ServiceRecord=service_record).outputs["DispatchID"]

    def check_fence(self, session, actor, order_id, location):
        self.orders.required(session, order_id, actor)
        return call_procedure(session, "usp_M2_CheckFence", OrderID=order_id, Location=location).outputs

    def order_details(self, session, actor, order_id):
        self.orders.required(session, order_id, actor)
        return session.execute(text("SELECT * FROM dbo.vw_M2_OrderDetails WHERE order_id=:pk"),
                               {"pk": order_id}).mappings().one()

    def blocked_scope(self, session, actor, caregiver_id):
        """展示正式限制视图；真正派单仍由过程在共同锁内重新检查。"""
        caregiver = BaseDAO("caregiver").required(session, caregiver_id, actor)
        return {
            "caregiver": list(session.execute(text("SELECT * FROM dbo.vw_M5_CaregiverBlocked WHERE caregiver_id=:pk"),
                                               {"pk": caregiver_id}).mappings()),
            "org": list(session.execute(text("SELECT * FROM dbo.vw_M5_OrgBlocked WHERE org_id=:pk"),
                                         {"pk": caregiver.org_id}).mappings()),
        }
