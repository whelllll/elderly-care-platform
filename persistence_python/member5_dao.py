"""成员5：补贴与整改业务入口；状态、汇总及触发器保持在同一工作单元。"""
from decimal import Decimal

from sqlalchemy import column, literal_column, select, table, text

from .base_dao import BaseDAO
from .errors import AccessDenied
from .models import (SubsidyApplication, SubsidyApplicationItem, SubsidyAuditLog, QualityInspection)
from .permissions import require
from .permissions.data_scope import predicate
from .permissions.tasks import require_assignment, audit_stage, audit_task_filter, require_audit_task
from .order_validation import positive_id
from .procedures import begin_sql_transaction, call_procedure


class Member5DAO:
    policies = BaseDAO("subsidy_policy")
    applications = BaseDAO("subsidy_application")
    items = BaseDAO("subsidy_application_item")
    audit_logs = BaseDAO("subsidy_audit_log")
    inspections = BaseDAO("quality_inspection")
    rectifications = BaseDAO("rectification")

    def __init__(self, task_policy=None):
        self.task_policy = task_policy

    def application_progress(self, session, actor, application_id):
        self.applications.required(session, application_id, actor)
        return session.execute(text("SELECT * FROM dbo.vw_M5_ApplicationProgress WHERE application_id=:pk"),
                               {"pk": application_id}).mappings().one()

    def subsidy_trace(self, session, actor, application_id):
        self.applications.required(session, application_id, actor)
        require(actor, "subsidy_application_item:read")
        view = table("vw_M5_SubsidyTrace", column("item_id"), column("application_id"), schema="dbo").alias("v")
        items = SubsidyApplicationItem.__table__
        stmt = select(literal_column("v.*")).select_from(view.join(items, view.c.item_id == items.c.item_id)).where(
            view.c.application_id == application_id, predicate("subsidy_application_item", items.c, actor))
        # 通配视图结果是Core映射，避免ORM将v.*误认为单个映射字段。
        return list(session.connection().execute(stmt).mappings())

    @staticmethod
    def _audit_org(actor):
        if not actor.audit_org or not actor.audit_org.strip() or len(actor.audit_org) > 60:
            raise AccessDenied("请由后端配置有效的审核/监管单位名称，不能用用户名代替。")
        return actor.audit_org

    def create_inspection(self, session, actor, *, object_type, inspect_method, inspect_result,
                          order_id=None, caregiver_id=None, inspect_time=None, inspect_source=None,
                          score=None, authenticity=None, problem_tags=None, rectify_flag="N",
                          rectify_deadline=None, inspect_status="已完成", remark=None):
        require(actor, "quality_inspection:write")
        if object_type == "订单" and order_id is not None and caregiver_id is None:
            BaseDAO("service_order").required(session, order_id, actor)
        elif object_type == "护工" and caregiver_id is not None and order_id is None:
            BaseDAO("caregiver").required(session, caregiver_id, actor)
        else:
            raise ValueError("抽查对象必须是且仅是一个订单或护工。")
        obj = QualityInspection(object_type=object_type, order_id=order_id, caregiver_id=caregiver_id,
            inspect_method=inspect_method, inspect_result=inspect_result, inspector_id=actor.user_id,
            inspector_org=self._audit_org(actor), inspect_time=inspect_time or session.scalar(text("SELECT SYSDATETIME()")),
            inspect_source=inspect_source, score=score, authenticity=authenticity, problem_tags=problem_tags,
            rectify_flag=rectify_flag, rectify_deadline=rectify_deadline, inspect_status=inspect_status, remark=remark)
        session.add(obj)
        session.flush()
        return obj.inspection_id

    def create_application(self, session, actor, *, elder_id, policy_id, settle_cycle):
        require(actor, "subsidy:create")
        BaseDAO("elder_profile").required(session, elder_id, actor)
        self.policies.required(session, policy_id, actor)
        return call_procedure(session, "usp_M5_CreateApplication", elder_id=elder_id, policy_id=policy_id,
                              settle_cycle=settle_cycle, create_by=str(actor.user_id)).outputs["application_id"]

    def _lock_application(self, session, actor, application_id):
        begin_sql_transaction(session)
        obj = session.scalar(self.applications._query(actor).where(SubsidyApplication.application_id == application_id)
                       .with_hint(SubsidyApplication, "WITH (UPDLOCK, HOLDLOCK)", "mssql")
                       .execution_options(populate_existing=True))
        if obj is None:
            raise AccessDenied("记录不存在或不在当前数据范围。")
        return obj

    def audit_todos(self, session, actor, *, page=1, size=20):
        """专用审核待办；普通申报查询仍保留原有只读可见范围。"""
        audit_stage(actor)
        if isinstance(page, bool) or isinstance(size, bool) or not isinstance(page, int) or not isinstance(size, int) or page < 1 or not 1 <= size <= 200:
            raise ValueError("页码必须为正整数，每页数量为1..200。")
        stmt = self.applications._query(actor).where(audit_task_filter(SubsidyApplication.__table__.c, actor))
        return list(session.scalars(stmt.order_by(SubsidyApplication.application_id)
                    .offset((page - 1) * size).limit(size).execution_options(populate_existing=True)))

    def check_audit_task(self, session, actor, application_id):
        """锁内归属检查组件，不认领、不写状态、不提交；跨节点规则确认后再接入audit。"""
        audit_stage(actor)
        positive_id(application_id, "application_id")
        obj = self._lock_application(session, actor, application_id)
        require_audit_task(actor, obj)
        return {"application_id": obj.application_id, "audit_status": obj.audit_status,
                "current_auditor_id": obj.current_auditor_id}

    def assign_auditor(self, session, actor, application_id, assignee_id):
        require(actor, "subsidy:assign")
        positive_id(application_id, "application_id")
        positive_id(assignee_id, "assignee_id")
        self.applications.required(session, application_id, actor)
        return call_procedure(session, "usp_M5_AssignAuditor", application_id=application_id,
                              assignee_id=assignee_id).outputs["assigned_to"]

    def add_item(self, session, actor, application_id, *, order_id, subsidy_amount, self_pay_amount=0, work_id=None):
        require(actor, "subsidy:details")
        application = self._lock_application(session, actor, application_id)
        if application.audit_status != "待社区初审":
            raise ValueError("只能修改待社区初审的申报明细。")
        order = BaseDAO("service_order").required(session, order_id, actor)
        policy = self.policies.required(session, application.policy_id, actor)
        if order.elder_id != application.elder_id or order.service_id != policy.service_item_id:
            raise ValueError("订单与申报老人或政策服务项目不匹配。")
        if order.order_status != "已完成" or order.confirm_status != "已确认":
            raise ValueError("只能申报已完成且确认的订单。")
        hours = None
        if work_id is not None:
            work = BaseDAO("work_record").required(session, work_id, actor)
            dispatch = BaseDAO("dispatch_record").required(session, work.dispatch_id, actor)
            if dispatch.order_id != order_id or work.review_status != "通过" or work.effective_minutes is None:
                raise ValueError("工时未审核通过或不属于该订单。")
            hours = Decimal(work.effective_minutes) / Decimal(60)
        obj = SubsidyApplicationItem(application_id=application_id, order_id=order_id, work_id=work_id,
                                     service_amount=order.total_amount, subsidy_amount=subsidy_amount,
                                     self_pay_amount=self_pay_amount, valid_hours=hours)
        session.add(obj)
        session.flush()
        item_id = obj.item_id
        call_procedure(session, "usp_M5_RefreshTotals", application_id=application_id)
        return item_id

    def audit(self, session, actor, application_id, *, action="通过", opinion=None):
        # 保留V2.1写行为：跨节点current_auditor_id契约未确认，暂不接入新归属组件。
        require(actor, "subsidy:audit")
        require(actor, "subsidy:community_audit" if actor.role_code == "COMMUNITY_ADMIN"
                else "subsidy:street_audit")
        obj = self._lock_application(session, actor, application_id)
        require_assignment(self.task_policy, session, actor, "subsidy:audit", application_id)
        audit_org = self._audit_org(actor)
        stages = {"COMMUNITY_ADMIN": ("待社区初审", "社区初审", "街道复审中"),
                  "STREET_SUPERVISOR": ("街道复审中", "街道复审", "民政终审中")}
        before, node, after = stages[actor.role_code]
        if obj.audit_status != before:
            raise AccessDenied("该角色不能处理当前审核节点。")
        if action not in {"通过", "驳回", "退回补正"}:
            raise ValueError("当前审核节点或操作不合法。")
        if action == "驳回" and not opinion:
            raise ValueError("驳回必须填写意见。")
        after = {"驳回": "审核驳回", "退回补正": "退回补正"}.get(action, after)
        obj.audit_status, obj.current_auditor_id = after, actor.user_id
        if after in {"审核通过", "审核驳回"}:
            obj.audit_finish_time = session.scalar(text("SELECT SYSDATETIME()"))
        session.add(SubsidyAuditLog(application_id=application_id, audit_node=node, auditor_id=actor.user_id,
                                   auditor_org=audit_org, audit_action=action, audit_opinion=opinion,
                                   before_status=before, after_status=after))
        session.flush()

    def pay(self, session, actor, application_id, voucher_no):
        require(actor, "subsidy:pay")
        obj = self._lock_application(session, actor, application_id)
        if obj.audit_status != "审核通过" or obj.pay_status == "已拨付" or not voucher_no:
            raise ValueError("需审核通过、尚未拨付且提供拨付凭证。")
        obj.pay_status, obj.pay_voucher_no = "已拨付", voucher_no
        obj.pay_time = session.scalar(text("SELECT SYSDATETIME()"))
        session.flush()

    def create_rectification(self, session, actor, *, inspection_id, org_id, caregiver_id=None,
                             problem_desc=None, requirement=None, deadline=None):
        require(actor, "rectification:create")
        inspection = self.inspections.required(session, inspection_id, actor)
        BaseDAO("service_org").required(session, org_id, actor)
        if caregiver_id is not None:
            caregiver = BaseDAO("caregiver").required(session, caregiver_id, actor)
            if caregiver.org_id != org_id or (inspection.caregiver_id is not None and inspection.caregiver_id != caregiver_id):
                raise ValueError("整改护工、机构或抽查对象不匹配。")
        return call_procedure(session, "usp_M5_CreateRectification", inspection_id=inspection_id, org_id=org_id,
                              caregiver_id=caregiver_id, problem_desc=problem_desc, requirement=requirement,
                              deadline=deadline).outputs["rectify_id"]

    def submit_rectification(self, session, actor, rectify_id):
        require(actor, "rectification:submit")
        obj = self._lock_rectification(session, actor, rectify_id)
        if obj.rectify_status not in {"待整改", "整改中", "复查不通过", "逾期未改"}:
            raise ValueError("当前整改状态不能提交。")
        obj.submit_time = session.scalar(text("SELECT SYSDATETIME()"))
        obj.rectify_status = "待复查"
        session.flush()

    def _lock_rectification(self, session, actor, rectify_id):
        obj = self.rectifications.required(session, rectify_id, actor)
        org_id, caregiver_id = obj.org_id, obj.caregiver_id
        locked = call_procedure(session, "usp_M5_LockScope", org_id=org_id, caregiver_id=caregiver_id).outputs
        if not locked["locked"]:
            raise ValueError(locked["reason"])
        obj = self.rectifications.required(session, rectify_id, actor)
        if (obj.org_id, obj.caregiver_id) != (org_id, caregiver_id):
            raise ValueError("整改归属在加锁前发生变化，请重试。")
        return obj

    def review_rectification(self, session, actor, rectify_id, review_result, remark=None):
        require(actor, "rectification:review")
        # 在共同锁内重新读状态，避免两个复查请求都使用锁前的“待复查”快照。
        obj = self._lock_rectification(session, actor, rectify_id)
        if obj.submit_time is None or obj.rectify_status != "待复查":
            raise ValueError("必须先提交整改，再进行复查。")
        return call_procedure(session, "usp_M5_ReviewRectification", rectify_id=rectify_id,
                              reviewer_id=actor.user_id, review_result=review_result, remark=remark).outputs["restrict_flag"]
