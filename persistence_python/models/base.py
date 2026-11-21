"""从正式DDL反射字段、主键、IDENTITY、默认值和计算列，不创建或迁移表。"""
from sqlalchemy.ext.declarative import DeferredReflection
from sqlalchemy.orm import DeclarativeBase


class Base(DeferredReflection, DeclarativeBase):
    __abstract__ = True
    __table_args__ = {"schema": "dbo", "implicit_returning": False}
