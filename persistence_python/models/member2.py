from .base import Base


class DispatchRecord(Base):
    __tablename__ = "dispatch_record"


class ServiceItem(Base):
    __tablename__ = "service_item"


class ServiceOrder(Base):
    __tablename__ = "service_order"
