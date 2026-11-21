"""不提交事务的受控CRUD。所有公开操作都要求后端认证得到的Principal。"""
from sqlalchemy import inspect, literal, select

from .errors import AccessDenied
from .models import TABLE_MODELS
from .permissions import require
from .permissions.data_scope import predicate

# 这些表的业务状态只能经模块业务方法修改。
CONTROLLED = {"service_order", "dispatch_record", "work_record", "emergency_event",
              "rectification", "quality_inspection", "subsidy_application", "subsidy_application_item", "subsidy_audit_log", "sys_user"}


class BaseDAO:
    def __init__(self, model):
        self.model = TABLE_MODELS[model] if isinstance(model, str) else model
        self.table = self.model.__tablename__

    def _query(self, actor, filters=None):
        require(actor, self.table + ":read")
        columns = self.model.__table__.c
        stmt = select(self.model).where(predicate(self.table, columns, actor))
        for name, value in (filters or {}).items():
            if name not in columns:
                raise ValueError("不允许的查询字段。")
            stmt = stmt.where(columns[name] == value)
        return stmt

    def get(self, session, pk, actor):
        key = inspect(self.model).primary_key[0]
        return session.scalars(self._query(actor).where(key == pk).execution_options(populate_existing=True)).one_or_none()

    def required(self, session, pk, actor):
        obj = self.get(session, pk, actor)
        if obj is None:
            raise AccessDenied("记录不存在或不在当前数据范围。")
        return obj

    def page(self, session, actor, page=1, size=20, order_by=None, filters=None):
        if isinstance(page, bool) or isinstance(size, bool) or not isinstance(page, int) or not isinstance(size, int) or page < 1 or not 1 <= size <= 200:
            raise ValueError("页码必须为正整数，每页数量为1..200。")
        columns = self.model.__table__.c
        name = order_by or inspect(self.model).primary_key[0].name
        if name not in columns:
            raise ValueError("不允许的排序字段。")
        tie_breakers = [col for col in inspect(self.model).primary_key if col.name != name]
        return list(session.scalars(self._query(actor, filters).order_by(columns[name], *tie_breakers)
                                   .offset((page - 1) * size).limit(size)))

    def get_all(self, session, actor):
        """无分页导出，调用方自行限制规模；仍强制数据范围。"""
        return list(session.scalars(self._query(actor).order_by(*inspect(self.model).primary_key)))

    def check_values(self, session, values, actor):
        require(actor, self.table + ":write")
        if self.table == "quality_inspection" and values.get("inspector_id") != actor.user_id:
            raise AccessDenied("抽查人员必须为当前登录账号。")
        if self.table == "vital_sign":
            device = BaseDAO("monitor_device").required(session, values.get("device_id"), actor)
            if device.elder_id != values.get("elder_id"):
                raise AccessDenied("设备与老人档案不匹配。")
        c = self.model.__table__.c
        row = select(*(literal(values.get(col.name), type_=col.type).label(col.name) for col in c)).subquery()
        if session.scalar(select(literal(1)).select_from(row).where(predicate(self.table, row.c, actor)).limit(1)) != 1:
            raise AccessDenied("待写入数据不在当前数据范围。")

    def _writable(self, actor):
        require(actor, self.table + ":write")
        if self.table in CONTROLLED:
            raise AccessDenied("该表只能通过对应模块的业务方法写入。")

    def _validate_fields(self, values, *, creating=False):
        columns = self.model.__table__.c
        for name in values:
            if name not in columns or columns[name].primary_key or columns[name].computed is not None:
                raise ValueError("包含未知、主键或计算字段。")

    def add(self, session, values, actor):
        self._writable(actor)
        self._validate_fields(values, creating=True)
        self.check_values(session, values, actor)
        obj = self.model(**values)
        session.add(obj)
        session.flush()
        return obj

    def update(self, session, pk, actor, **changes):
        self._writable(actor)
        self._validate_fields(changes)
        obj = self.required(session, pk, actor)
        merged = {col.name: getattr(obj, col.name) for col in self.model.__table__.c}
        merged.update(changes)
        self.check_values(session, merged, actor)
        for name, value in changes.items():
            setattr(obj, name, value)
        if "updated_at" in self.model.__table__.c:
            from datetime import datetime
            obj.updated_at = datetime.now()
        session.flush()
        return obj

    def delete(self, session, pk, actor):
        self._writable(actor)
        require(actor, self.table + ":write")
        obj = self.required(session, pk, actor)
        self.check_values(session, {col.name: getattr(obj, col.name) for col in self.model.__table__.c}, actor)
        session.delete(obj)
        session.flush()

    def batch_add(self, session, objects, actor):
        self._writable(actor)
        objects = list(objects)
        for values in objects:
            self._validate_fields(values, creating=True)
            self.check_values(session, values, actor)
        result = [self.model(**values) for values in objects]
        session.add_all(result)
        session.flush()
        return result

    def batch_update(self, session, updates, actor):
        """先验证全部主键、字段和范围，再统一赋值及flush；调用方负责工作单元提交。"""
        self._writable(actor)
        updates = list(updates)
        seen, prepared = set(), []
        for pk, changes in updates:
            if pk in seen:
                raise ValueError("批量更新包含重复主键。")
            seen.add(pk)
            self._validate_fields(changes)
            obj = self.required(session, pk, actor)
            merged = {col.name: getattr(obj, col.name) for col in self.model.__table__.c}
            merged.update(changes)
            self.check_values(session, merged, actor)
            prepared.append((obj, changes))
        for obj, changes in prepared:
            for name, value in changes.items():
                setattr(obj, name, value)
            if "updated_at" in self.model.__table__.c:
                from sqlalchemy import text
                obj.updated_at = session.scalar(text("SELECT SYSDATETIME()"))
        session.flush()
        return [obj for obj, _ in prepared]
