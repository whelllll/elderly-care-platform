from .base import Base


class Caregiver(Base):
    __tablename__ = "caregiver"


class CaregiverCertificate(Base):
    __tablename__ = "caregiver_certificate"


class CaregiverSchedule(Base):
    __tablename__ = "caregiver_schedule"


class WorkRecord(Base):
    __tablename__ = "work_record"
