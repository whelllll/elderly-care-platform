"""两个独立SQL Server连接；用服务端阻塞状态证明交错，而非仅顺序执行。"""
from concurrent.futures import ThreadPoolExecutor
from threading import Event
from time import monotonic
from uuid import uuid4

import pytest
from sqlalchemy import text

from .models import ServiceItem


@pytest.mark.parametrize("commit_writer", [True, False], ids=["commit", "rollback"])
def test_two_connections_lock_isolation_and_final_value(database, commit_writer):
    name = "PYCONCURRENT:" + uuid4().hex[:12]
    with database.session() as session:
        row = ServiceItem(service_name=name, service_type="家政", price=10, duration=30, charge_unit="次")
        session.add(row)
        session.flush()
        pk = row.service_id
    writer = database.session_factory()
    ready = Event()
    reader_info = {}

    def read_and_update():
        with database.session() as reader:
            reader.execute(text("SET LOCK_TIMEOUT 10000"))
            reader_info["spid"] = reader.scalar(text("SELECT @@SPID"))
            ready.set()
            # READ COMMITTED下不能读到未提交的价格20。
            seen = reader.scalar(text("SELECT price FROM dbo.service_item WITH (READCOMMITTEDLOCK) WHERE service_id=:pk"), {"pk": pk})
            reader.execute(text("UPDATE dbo.service_item SET price=price+2 WHERE service_id=:pk"), {"pk": pk})
            return seen

    try:
        writer_id = writer.scalar(text("SELECT @@SPID"))
        writer.execute(text("UPDATE dbo.service_item SET price=20 WHERE service_id=:pk"), {"pk": pk})
        with ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(read_and_update)
            try:
                assert ready.wait(5), "第二个连接未能及时建立"
                assert reader_info["spid"] != writer_id
                deadline, blocked = monotonic() + 5, False
                with database.engine.connect() as observer:
                    while monotonic() < deadline:
                        blocker = observer.scalar(text("SELECT blocking_session_id FROM sys.dm_exec_requests WHERE session_id=:spid"),
                                                  {"spid": reader_info["spid"]})
                        if blocker == writer_id:
                            blocked = True
                            break
                        Event().wait(0.02)
                assert blocked, "未观测到第二连接被第一连接的真实行锁阻塞"
            finally:
                # 即使断言失败也先释放锁，避免线程池等待被锁住的查询。
                writer.commit() if commit_writer else writer.rollback()
            seen = future.result(timeout=12)
        assert seen == (20 if commit_writer else 10)
        with database.session() as session:
            assert session.get(ServiceItem, pk).price == (22 if commit_writer else 12)
    finally:
        writer.rollback()
        writer.close()
        with database.session() as session:
            row = session.get(ServiceItem, pk)
            if row is not None and row.service_name == name:
                session.delete(row)
