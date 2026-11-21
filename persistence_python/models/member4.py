from .base import Base


class EmergencyEvent(Base):
    __tablename__ = "emergency_event"


class MonitorDevice(Base):
    __tablename__ = "monitor_device"


class SysUser(Base):
    __tablename__ = "sys_user"


class VitalSign(Base):
    __tablename__ = "vital_sign"
