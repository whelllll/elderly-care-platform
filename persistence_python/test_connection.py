import pytest
from sqlalchemy import inspect, text

from .db import Database
from .models import MODELS


@pytest.mark.parametrize("name", ["master", "tempdb", "model", "msdb", "MASTER", ""])
def test_system_database_rejected(name):
    with pytest.raises(ValueError):
        Database("mssql+pyodbc://localhost/" + name)


def test_missing_configuration(monkeypatch):
    monkeypatch.delenv("ELDERCARE_DATABASE_URL", raising=False)
    with pytest.raises(ValueError):
        Database()


def test_unsupported_driver():
    with pytest.raises(ValueError):
        Database("sqlite:///:memory:")


def test_real_connection_and_22_models(database):
    with database.engine.connect() as connection:
        assert connection.scalar(text("SELECT DB_NAME()")).startswith("Codex_Persistence_")
    assert len(MODELS) == 22
    inspector = inspect(database.engine)
    for model in MODELS:
        actual = inspector.get_columns(model.__tablename__, schema="dbo")
        assert set(model.__table__.c.keys()) == {col["name"] for col in actual}
        assert model.__table__.primary_key
        for col in actual:
            mapped = model.__table__.c[col["name"]]
            assert str(mapped.type) == str(col["type"])
            assert mapped.nullable == col["nullable"]
            assert bool(mapped.identity) == bool(col.get("identity"))
            assert bool(mapped.computed) == bool(col.get("computed"))
        actual_fks = inspector.get_foreign_keys(model.__tablename__, schema="dbo")
        assert len(model.__table__.foreign_key_constraints) == len(actual_fks)


def test_procedure_parameter_contracts_match_formal_sql(database):
    from .procedures import PROCEDURES
    with database.session() as session:
        for name, (inputs, outputs) in PROCEDURES.items():
            rows = session.execute(text("""SELECT p.name, p.is_output FROM sys.parameters AS p
                WHERE p.object_id=OBJECT_ID(:name)"""), {"name": "dbo." + name}).all()
            actual = {row.name.lstrip("@").lower(): row.is_output for row in rows}
            assert actual, name
            assert {key.lower() for key in inputs | set(outputs)} == set(actual), name
            assert all(actual[key.lower()] for key in outputs), name
