from .base import Base


class QualityInspection(Base):
    __tablename__ = "quality_inspection"


class Rectification(Base):
    __tablename__ = "rectification"


class SubsidyApplication(Base):
    __tablename__ = "subsidy_application"


class SubsidyApplicationItem(Base):
    __tablename__ = "subsidy_application_item"


class SubsidyAuditLog(Base):
    __tablename__ = "subsidy_audit_log"


class SubsidyPolicy(Base):
    __tablename__ = "subsidy_policy"
