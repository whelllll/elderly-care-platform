from threading import Lock

from sqlalchemy import inspect

from .base import Base
from .member1 import AbilityAssessment, CarePlan, CarePlanItem, ElderProfile, ServiceOrg
from .member2 import DispatchRecord, ServiceItem, ServiceOrder
from .member3 import Caregiver, CaregiverCertificate, CaregiverSchedule, WorkRecord
from .member4 import EmergencyEvent, MonitorDevice, SysUser, VitalSign
from .member5 import QualityInspection, Rectification, SubsidyApplication, SubsidyApplicationItem, SubsidyAuditLog, SubsidyPolicy

MODELS = (AbilityAssessment, CarePlan, CarePlanItem, ElderProfile, ServiceOrg, DispatchRecord, ServiceItem, ServiceOrder, Caregiver, CaregiverCertificate, CaregiverSchedule, WorkRecord, EmergencyEvent, MonitorDevice, SysUser, VitalSign, QualityInspection, Rectification, SubsidyApplication, SubsidyApplicationItem, SubsidyAuditLog, SubsidyPolicy,)
TABLE_MODELS = {model.__tablename__: model for model in MODELS}
_prepare_lock = Lock()


def prepare_models(engine):
    with _prepare_lock:
        available = set(inspect(engine).get_table_names(schema="dbo"))
        missing = set(TABLE_MODELS) - available
        if missing:
            raise ValueError("缺少正式数据表：" + ", ".join(sorted(missing)))
        if not hasattr(MODELS[0], "__mapper__"):
            Base.prepare(engine)
