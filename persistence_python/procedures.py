"""仅允许固定过程及参数。与ORM共用连接，消费多结果集，不自行提交。"""
from dataclasses import dataclass, field

from sqlalchemy import text

# 输入参数白名单；输出类型是源码常量，不能由请求传入SQL标识符/类型。
PROCEDURES = {
    "usp_GetElderCareOverview": ({"elder_id"}, {}),
    "usp_M2_CreateOrder": ({"ElderID", "ServiceID", "AppointmentTime", "ServiceAddress", "Latitude",
                           "Longitude", "RadiusM", "Remark", "OrderChannel"}, {"OrderID": "INT"}),
    "usp_M2_OrderAction": ({"OrderID", "Action", "CaregiverID", "Reason", "Confirmed", "ServiceRecord"},
                            {"DispatchID": "INT"}),
    "usp_M2_CheckFence": ({"OrderID", "Location"}, {"FenceResult": "NVARCHAR(10)", "DistanceM": "FLOAT"}),
    "sp_raise_emergency": ({"elder_id", "trigger_source", "event_level", "happen_time"}, {"event_id": "INT"}),
    "sp_accept_emergency": ({"event_id", "responder_id"}, {}),
    "sp_close_emergency": ({"event_id", "arrive_time", "dispose_result"}, {}),
    "usp_M5_CreateApplication": ({"elder_id", "policy_id", "settle_cycle", "create_by"}, {"application_id": "INT"}),
    "usp_M5_RefreshTotals": ({"application_id"}, {}),
    "usp_M5_AssignAuditor": ({"application_id", "assignee_id"}, {"assigned_to": "INT"}),
    "usp_M5_LockScope": ({"org_id", "caregiver_id"}, {"locked": "BIT", "reason": "NVARCHAR(100)"}),
    "usp_M5_CreateRectification": ({"inspection_id", "caregiver_id", "org_id", "problem_desc", "requirement", "deadline"},
                                   {"rectify_id": "INT"}),
    "usp_M5_ReviewRectification": ({"rectify_id", "reviewer_id", "review_result", "remark"}, {"restrict_flag": "CHAR(1)"}),
}


@dataclass
class ProcedureResult:
    outputs: dict = field(default_factory=dict)
    result_sets: list[list[dict]] = field(default_factory=list)


def begin_sql_transaction(session):
    # Session.begin()只启动逻辑事务；过程可能在首条DML之前看到@@TRANCOUNT=0。
    # 显式BEGIN保证过程不会误将整个工作单元当成自己的事务并提前COMMIT。
    session.execute(text("IF @@TRANCOUNT = 0 BEGIN TRANSACTION;"))


def call_procedure(session, name, **values):
    if name not in PROCEDURES:
        raise ValueError("不允许调用该存储过程。")
    inputs, outputs = PROCEDURES[name]
    if set(values) - inputs - set(outputs):
        raise ValueError("存储过程包含未知参数。")
    params, declarations, arguments = [], [], []
    for key, sql_type in outputs.items():
        declarations.append(f"DECLARE @out_{key} {sql_type} = ?;")
        params.append(values.get(key))
    for key, value in values.items():
        if key not in outputs:
            arguments.append(f"@{key} = ?")
            params.append(value)
    arguments.extend(f"@{key} = @out_{key} OUTPUT" for key in outputs)
    projection = ", ".join(f"@out_{key} AS [{key}]" for key in outputs)
    sql = ("SET NOCOUNT ON; " + " ".join(declarations)
           + f" EXEC dbo.[{name}] " + ", ".join(arguments) + "; SELECT 1 AS __persistence_output__"
           + (", " + projection if projection else "") + ";")
    cursor = None
    try:
        begin_sql_transaction(session)
        session.flush()
        cursor = session.connection().connection.driver_connection.cursor()
        cursor.execute(sql, tuple(params))
        result = ProcedureResult()
        while True:
            if cursor.description:
                names = [column[0] for column in cursor.description]
                rows = [dict(zip(names, row)) for row in cursor.fetchall()]
                if names[0] == "__persistence_output__":
                    result.outputs = {key: rows[0][key] for key in outputs}
                else:
                    result.result_sets.append(rows)
            if not cursor.nextset():
                break
        session.expire_all()
        return result
    except Exception:
        # THROW/XACT_ABORT可能已使SQL Server事务不可提交；调用方工作单元整体失败。
        session.rollback()
        raise
    finally:
        if cursor is not None:
            cursor.close()


def lock_order_actions(session):
    begin_sql_transaction(session)
    result = session.scalar(text("""
        DECLARE @r INT;
        EXEC @r = sys.sp_getapplock @Resource=N'M2.OrderAction.v1', @LockMode=N'Exclusive',
             @LockOwner=N'Transaction', @LockTimeout=10000;
        SELECT @r;
    """))
    if result < 0:
        raise TimeoutError("订单业务事务锁获取失败。")
