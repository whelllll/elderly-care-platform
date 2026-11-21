"""显式配置业务库，由会话上下文统一提交或回滚。"""
from contextlib import contextmanager
import os

from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlalchemy.orm import sessionmaker

SYSTEM_DATABASES = {"master", "tempdb", "model", "msdb"}


class Database:
    def __init__(self, url=None):
        url = url or os.environ.get("ELDERCARE_DATABASE_URL")
        if not url:
            raise ValueError("请设置 ELDERCARE_DATABASE_URL，明确指定养老服务业务数据库。")
        parsed = make_url(url)
        if parsed.drivername != "mssql+pyodbc":
            raise ValueError("当前持久层仅支持 mssql+pyodbc。")
        if not parsed.database or parsed.database.lower() in SYSTEM_DATABASES:
            raise ValueError("必须连接显式指定的用户数据库，禁止使用系统数据库。")
        self.engine = create_engine(parsed, pool_pre_ping=True, echo=False, hide_parameters=True)
        self.session_factory = sessionmaker(bind=self.engine, expire_on_commit=False)

    def initialize(self, *, validate_b3=True):
        from .models import prepare_models

        with self.engine.connect() as connection:
            actual = connection.scalar(text("SELECT DB_NAME()"))
            if actual.lower() in SYSTEM_DATABASES:
                raise ValueError("实际连接到了系统数据库。")
        prepare_models(self.engine)
        if validate_b3 and os.environ.get("ELDERCARE_PROFILE", "").upper() == "B3":
            from .security.accounts import audit_b3_accounts, load_manifest
            path = os.environ.get("ELDERCARE_B3_ACCOUNT_MANIFEST")
            if not path:
                raise ValueError("B3启动前必须配置ELDERCARE_B3_ACCOUNT_MANIFEST并核验28个独立凭据。")
            with self.session() as session:
                audit_b3_accounts(session, [entry["username"] for entry in load_manifest(path)])
        return self

    @contextmanager
    def session(self):
        with self.session_factory() as session:
            with session.begin():
                yield session

    def close(self):
        self.engine.dispose()


_database = None


def configure(url=None):
    global _database
    database = Database(url)
    try:
        database.initialize()
    except Exception:
        database.close()
        raise
    if _database is not None:
        _database.close()
    _database = database
    return database


def get_database():
    if _database is None:
        return configure()
    return _database


def get_session():
    return get_database().session()


def SessionLocal():
    """手动会话兼容入口；调用方必须自行提交/回滚及关闭。"""
    return get_database().session_factory()
