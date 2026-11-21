from .base import Base


class AbilityAssessment(Base):
    __tablename__ = "ability_assessment"


class CarePlan(Base):
    __tablename__ = "care_plan"


class CarePlanItem(Base):
    __tablename__ = "care_plan_item"


class ElderProfile(Base):
    __tablename__ = "elder_profile"


class ServiceOrg(Base):
    __tablename__ = "service_org"
