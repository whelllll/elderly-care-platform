from uuid import uuid4

import pytest
from sqlalchemy import text

from .models import ServiceItem
from .procedures import call_procedure
from .test_business import create_order


def test_procedure_output_does_not_commit_callers_transaction(session, fixture, database):
    order_id = create_order(session, fixture)
    assert session.scalar(text("SELECT @@TRANCOUNT")) >= 1
    session.rollback()
    with database.engine.connect() as connection:
        assert connection.scalar(text("SELECT COUNT(*) FROM dbo.service_order WHERE order_id=:pk"), {"pk": order_id}) == 0


def test_unknown_procedure_and_parameters_rejected_before_sql(session):
    with pytest.raises(ValueError):
        call_procedure(session, "usp_bad; DROP TABLE dbo.service_item")
    with pytest.raises(ValueError):
        call_procedure(session, "usp_M2_CreateOrder", InvalidParameter=1)


def test_session_context_commit_and_exception_rollback(database):
    name = "PYUOW:" + uuid4().hex[:16]
    pk = None
    try:
        with database.session() as session:
            obj = ServiceItem(service_name=name, service_type="家政", price=1, duration=30, charge_unit="次")
            session.add(obj)
            session.flush()
            pk = obj.service_id
        with database.engine.connect() as connection:
            assert connection.scalar(text("SELECT COUNT(*) FROM dbo.service_item WHERE service_id=:pk"), {"pk": pk}) == 1
        with pytest.raises(RuntimeError):
            with database.session() as session:
                session.add(ServiceItem(service_name=name+"B", service_type="家政", price=1, duration=30, charge_unit="次"))
                session.flush()
                raise RuntimeError("模拟后续业务异常")
        with database.engine.connect() as connection:
            assert connection.scalar(text("SELECT COUNT(*) FROM dbo.service_item WHERE service_name=:name"), {"name": name+"B"}) == 0
    finally:
        if pk is not None:
            with database.session() as session:
                obj = session.get(ServiceItem, pk)
                if obj is not None:
                    session.delete(obj)


def test_batch_insert_update_all_roll_back_on_later_database_failure(database):
    from sqlalchemy.exc import IntegrityError
    from .base_dao import BaseDAO
    from .conftest import build_fixture
    names = ["PYBATCHROLLBACK:" + uuid4().hex[:12] + str(i) for i in range(3)]
    with pytest.raises(IntegrityError):
        with database.session() as session:
            f = build_fixture(session)
            dao, actor = BaseDAO("service_item"), f["actors"]["COMMUNITY_ADMIN"]
            rows = dao.batch_add(session, [dict(service_name=name, service_type="家政", price=1,
                                                 duration=30, charge_unit="次") for name in names], actor)
            dao.batch_update(session, [(row.service_id, {"price": 10}) for row in rows], actor)
            assert all(row.price == 10 for row in rows)
            # 后续真正触发正式CHECK，而非只抛Python异常。
            dao.update(session, rows[-1].service_id, actor, price=-1)
    with database.session() as session:
        assert session.scalar(text("SELECT COUNT(*) FROM dbo.service_item WHERE service_name IN (:a,:b,:c)"),
                              dict(zip(("a", "b", "c"), names))) == 0
