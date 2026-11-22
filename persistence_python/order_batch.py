"""20条专用订单：只读预检与显式执行；不维护其他成员基础数据。"""
import argparse
from collections import Counter
from datetime import datetime, timedelta
from getpass import getpass
import json
import os
import re

from sqlalchemy import text

from .base_dao import BaseDAO
from .member2_dao import Member2DAO
from .order_validation import positive_id, validate_order
from .permissions import require
from .procedures import begin_sql_transaction


def load_batch(path):
    with open(path, encoding="utf-8-sig") as stream:
        batch = json.load(stream)
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,40}", batch.get("batch", "")):
        raise ValueError("batch须为1..40位字母、数字、下划线或连字符。")
    entries = batch["orders"]
    if len(entries) != 20:
        raise ValueError("专用批次必须精确提供20组参数。")
    for entry in entries:
        entry["appointment_time"] = datetime.fromisoformat(entry["appointment_time"])
        positive_id(entry["caregiver_id"], "caregiver_id")
        positive_id(entry["schedule_id"], "schedule_id")
        validate_order(**order_values(entry, batch["batch"]))
        if not entry.get("caregiver_username") or not entry.get("password_env"):
            raise ValueError("每条需提供实际护工username及密码环境变量名。")
    return batch


def marker(batch):
    return "M2:BATCH:" + batch


def order_values(entry, batch):
    return {**{key: entry[key] for key in ("elder_id", "service_id", "appointment_time", "service_address")},
            **{key: entry[key] for key in ("latitude", "longitude", "radius_m", "order_channel") if key in entry},
            "remark": marker(batch)}


def preflight(session, actor, batch):
    """提示性快照，无写入/占容量；过程在统一锁内再次检查全部条件。"""
    require(actor, "order:create")
    require(actor, "order:dispatch")
    entries = batch["orders"]
    if len(entries) != 20:
        raise ValueError("必须精确20条。")
    if session.scalar(text("SELECT COUNT(*) FROM dbo.service_order WHERE remark=:mark"), {"mark": marker(batch["batch"])}):
        raise ValueError("批次已存在；禁止重跑重置进度，请按现有映射继续后续阶段。")
    for name, kind in (("usp_M5_LockScope", "P"), ("vw_M5_OrgBlocked", "V"), ("vw_M5_CaregiverBlocked", "V"),
                       ("usp_M2_CreateOrder", "P"), ("usp_M2_OrderAction", "P")):
        if not session.scalar(text("SELECT OBJECT_ID(:name, :kind)"), {"name": "dbo." + name, "kind": kind}):
            raise ValueError("缺少正式接口：" + name)
    now = session.scalar(text("SELECT SYSDATETIME()"))
    planned, capacity = [], Counter()
    for entry in entries:
        validate_order(**order_values(entry, batch["batch"]))
        positive_id(entry["caregiver_id"], "caregiver_id")
        positive_id(entry["schedule_id"], "schedule_id")
        elder = BaseDAO("elder_profile").required(session, entry["elder_id"], actor)
        item = BaseDAO("service_item").required(session, entry["service_id"], actor)
        cg = BaseDAO("caregiver").required(session, entry["caregiver_id"], actor)
        start = entry["appointment_time"]
        finish = start + timedelta(minutes=item.duration)
        if start <= now or item.status != "上架":
            raise ValueError("预约已过期或项目未上架。")
        if elder.community_name != entry["service_address"].split("-", 1)[0] or cg.service_area != elder.community_name or cg.employment_status != "在岗":
            raise ValueError("老人社区、服务地址、护工区域或在岗状态不匹配。")
        params = {"cg": cg.caregiver_id, "sid": entry["service_id"], "start": start, "finish": finish, "org": cg.org_id}
        if not session.scalar(text("""SELECT COUNT(*) FROM dbo.caregiver_certificate
            WHERE caregiver_id=:cg AND service_id=:sid AND certificate_status=N'有效'
            AND CONVERT(date,:start) BETWEEN valid_from AND valid_to"""), params):
            raise ValueError("护工缺少预约日期有效项目资质。")
        shifts = list(session.execute(text("""SELECT schedule_id,start_time,end_time,max_orders FROM dbo.caregiver_schedule
            WHERE caregiver_id=:cg AND schedule_status=N'开放' AND start_time<=:start AND end_time>=:finish"""), params).mappings())
        if len(shifts) != 1 or shifts[0]["schedule_id"] != entry["schedule_id"]:
            raise ValueError("预约须完整落在指定且唯一的开放班次内。")
        shift = shifts[0]
        params.update(schedule=entry["schedule_id"], shift_start=shift["start_time"], shift_end=shift["end_time"])
        if session.scalar(text("""SELECT COUNT(*) FROM dbo.caregiver_schedule WHERE caregiver_id=:cg
            AND schedule_id<>:schedule AND schedule_status<>N'取消' AND start_time<:shift_end AND end_time>:shift_start"""), params):
            raise ValueError("候选班次与其他未取消班次重叠。")
        if session.scalar(text("SELECT COUNT(*) FROM dbo.vw_M5_CaregiverBlocked WHERE caregiver_id=:cg"), params) or session.scalar(
                text("SELECT COUNT(*) FROM dbo.vw_M5_OrgBlocked WHERE org_id=:org"), params):
            raise ValueError("护工或机构存在整改限制。")
        if session.scalar(text("""SELECT COUNT(*) FROM dbo.dispatch_record d JOIN dbo.service_order o ON o.order_id=d.order_id
            WHERE d.caregiver_id=:cg AND d.dispatch_status IN (N'待接单',N'已接单')
            AND o.appointment_time<:finish AND DATEADD(minute,o.duration_minutes,o.appointment_time)>:start"""), params):
            raise ValueError("预约与现有派单冲突。")
        if any(c == cg.caregiver_id and s < finish and start < e for c, s, e in planned):
            raise ValueError("本批次内护工预约冲突。")
        planned.append((cg.caregiver_id, start, finish))
        capacity[entry["schedule_id"]] += 1
        used = session.scalar(text("""SELECT COUNT(*) FROM dbo.dispatch_record
            WHERE schedule_id=:schedule AND dispatch_status IN (N'待接单',N'已接单')"""), params)
        if used + capacity[entry["schedule_id"]] > shift["max_orders"]:
            raise ValueError("本批次与现有派单合计超过班次容量。")
        binding = session.execute(text("""SELECT role_code,caregiver_id,org_id,user_status FROM dbo.sys_user
            WHERE username=:name"""), {"name": entry["caregiver_username"]}).mappings().one_or_none()
        if not binding or binding["role_code"] != "CAREGIVER" or binding["caregiver_id"] != cg.caregiver_id or binding["org_id"] != cg.org_id or binding["user_status"] != "正常":
            raise ValueError("护工账号绑定或状态不正确。")
    return {"orders": 20, "status": "预检通过；不代表已派单或正式联调通过"}


def execute_batch(session, actor, batch, caregivers, *, b1_b2_accepted=False):
    if not b1_b2_accepted:
        raise ValueError("正式批次须等待成员1 B1/B2验收通过。")
    dao, result = Member2DAO(), []
    try:
        require(actor, "order:create")
        require(actor, "order:dispatch")
        # 同批次并发执行先串行化，再检查是否已存在；不替代派单过程的共同锁。
        begin_sql_transaction(session)
        locked = session.scalar(text("""DECLARE @r INT;
            EXEC @r=sys.sp_getapplock @Resource=:resource, @LockMode=N'Exclusive',
                 @LockOwner=N'Transaction', @LockTimeout=10000; SELECT @r;"""),
            {"resource": "M2.Batch:" + batch["batch"]})
        if locked < 0:
            raise TimeoutError("专用批次锁获取失败。")
        preflight(session, actor, batch)
        for entry in batch["orders"]:
            caregiver = caregivers[entry["caregiver_username"]]
            if caregiver.role_code != "CAREGIVER" or caregiver.caregiver_id != entry["caregiver_id"]:
                raise ValueError("接单身份与本条护工不匹配。")
            order_id = dao.create_order(session, actor, **order_values(entry, batch["batch"]))
            dispatch_id = dao.dispatch_order(session, actor, order_id, entry["caregiver_id"])
            dao.accept_order(session, caregiver, order_id, dispatch_id)
            order = dao.orders.required(session, order_id, actor)
            dispatch = dao.dispatches.required(session, dispatch_id, actor)
            if (order.order_status, dispatch.dispatch_status, dispatch.order_id, dispatch.caregiver_id, dispatch.schedule_id) != (
                    "待服务", "已接单", order_id, entry["caregiver_id"], entry["schedule_id"]):
                raise ValueError("订单、派单、护工或班次关联不符合批次要求。")
            result.append(dict(order_id=order_id, dispatch_id=dispatch_id, schedule_id=dispatch.schedule_id,
                               caregiver_id=dispatch.caregiver_id))
        return result
    except Exception:
        session.rollback()
        raise


def main():
    from .db import Database
    from .security import LoginService, SessionStore
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--username", required=True, help="有派单权限的实际社区账号")
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--b1-b2-accepted", action="store_true", help="仅在收到成员1验收结论后使用")
    args = parser.parse_args()
    batch = load_batch(args.manifest)
    if args.execute and not args.b1_b2_accepted:
        parser.error("执行前必须确认成员1 B1/B2验收通过")
    db = Database().initialize()
    try:
        store = SessionStore(LoginService(db))
        token = store.login(args.username, getpass("社区账号密码："))
        caregiver_tokens = {}
        if args.execute:
            for entry in batch["orders"]:
                name = entry["caregiver_username"]
                if name not in caregiver_tokens:
                    password = os.environ.get(entry["password_env"])
                    if not password:
                        raise ValueError("缺少护工密码环境变量。")
                    caregiver_tokens[name] = store.login(name, password)
        with db.session() as session:
            actor = store.resolve(session, token)
            caregivers = {name: store.resolve(session, value) for name, value in caregiver_tokens.items()}
            report = execute_batch(session, actor, batch, caregivers, b1_b2_accepted=args.b1_b2_accepted) if args.execute else preflight(session, actor, batch)
        print(json.dumps(report, ensure_ascii=False))
    finally:
        db.close()


if __name__ == "__main__":
    main()
