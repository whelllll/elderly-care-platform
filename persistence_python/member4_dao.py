"""成员4：设备/体征及使用正式过程的应急响应。"""
from .base_dao import BaseDAO
from .errors import AccessDenied
from .permissions import require
from .procedures import call_procedure


class Member4DAO:
    devices = BaseDAO("monitor_device")
    vital_signs = BaseDAO("vital_sign")
    emergencies = BaseDAO("emergency_event")
    users = BaseDAO("sys_user")

    def record_vital(self, session, actor, **values):
        device = self.devices.required(session, values.get("device_id"), actor)
        if device.elder_id != values.get("elder_id"):
            raise AccessDenied("设备与老人档案不匹配。")
        return self.vital_signs.add(session, values, actor)

    def raise_emergency(self, session, actor, *, elder_id, trigger_source, event_level, happen_time):
        require(actor, "emergency:raise")
        BaseDAO("elder_profile").required(session, elder_id, actor)
        return call_procedure(session, "sp_raise_emergency", elder_id=elder_id, trigger_source=trigger_source,
                              event_level=event_level, happen_time=happen_time).outputs["event_id"]

    def accept_emergency(self, session, actor, event_id):
        require(actor, "emergency:accept")
        self.emergencies.required(session, event_id, actor)
        call_procedure(session, "sp_accept_emergency", event_id=event_id, responder_id=actor.user_id)

    def close_emergency(self, session, actor, event_id, *, arrive_time, dispose_result):
        require(actor, "emergency:close")
        obj = self.emergencies.required(session, event_id, actor)
        if obj.responder_id != actor.user_id and actor.role_code != "COMMUNITY_ADMIN":
            raise AccessDenied("只能闭环自己负责的事件。")
        call_procedure(session, "sp_close_emergency", event_id=event_id, arrive_time=arrive_time,
                       dispose_result=dispose_result)
