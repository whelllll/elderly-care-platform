"""成员2参数预检。数据库过程仍是并发和业务规则的最终裁决者。"""
from datetime import datetime
from decimal import Decimal, InvalidOperation


def positive_id(value, name):
    if isinstance(value, bool) or not isinstance(value, int) or not 0 < value <= 2147483647:
        raise ValueError(name + "必须是实际查询得到的正整数ID。")


def bounded_text(value, name, limit, required=False):
    if value is None and not required:
        return
    if not isinstance(value, str) or (required and not value.strip()) or len(value.encode("utf-16-le")) // 2 > limit:
        raise ValueError(name + "为空或超过数据库字段长度。")


def validate_order(*, elder_id, service_id, appointment_time, service_address,
                   latitude=None, longitude=None, radius_m=None, remark=None, order_channel="电话"):
    positive_id(elder_id, "elder_id")
    positive_id(service_id, "service_id")
    if not isinstance(appointment_time, datetime) or appointment_time.tzinfo is not None or appointment_time.microsecond:
        raise ValueError("预约时间必须是数据库当地时间，精确到秒且不带时区。")
    bounded_text(service_address, "服务地址", 200, True)
    community, sep, detail = service_address.partition("-")
    if not sep or not community.strip() or community != community.strip() or not detail.strip():
        raise ValueError("服务地址须为社区名称-详细地址，社区首尾不能有空格。")
    bounded_text(remark, "备注", 255)
    if order_channel not in {"电话", "家属端", "社区代下单"}:
        raise ValueError("未知下单渠道。")
    fence = (latitude, longitude, radius_m)
    if any(v is not None for v in fence):
        if not all(v is not None for v in fence):
            raise ValueError("围栏经纬度及半径必须同时填写。")
        positive_id(radius_m, "radius_m")
        try:
            lat, lon = Decimal(str(latitude)), Decimal(str(longitude))
            if not lat.is_finite() or not lon.is_finite() or not -90 <= lat <= 90 or not -180 <= lon <= 180:
                raise ValueError("经纬度越界。")
        except InvalidOperation as exc:
            raise ValueError("经纬度必须为有效数值。") from exc


def validate_action(order_id, action, caregiver_id, dispatch_id, reason, confirmed, service_record):
    positive_id(order_id, "order_id")
    if not isinstance(action, str) or action.upper() not in {
            "DISPATCH", "REASSIGN", "ACCEPT", "REJECT", "WITHDRAW", "CANCEL", "START", "COMPLETE"}:
        raise ValueError("未知订单操作。")
    if caregiver_id is not None:
        positive_id(caregiver_id, "caregiver_id")
    if action.upper() in {"DISPATCH", "REASSIGN"}:
        positive_id(caregiver_id, "caregiver_id")
    if dispatch_id is not None or action.upper() in {"REASSIGN", "ACCEPT", "REJECT", "WITHDRAW", "START", "COMPLETE"}:
        positive_id(dispatch_id, "dispatch_id")
    bounded_text(reason, "原因", 255)
    if action.upper() == "REASSIGN":
        bounded_text(reason, "改派原因", 200, True)
    bounded_text(service_record, "服务记录", 500)
    if not isinstance(confirmed, bool):
        raise ValueError("confirmed必须是布尔值。")
