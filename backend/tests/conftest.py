import pytest
from sqlalchemy.pool import StaticPool

from truckmaps.core.db import Base, Database


@pytest.fixture
def database() -> Database:
    """Pusta baza SQLite w pamięci, wspólna dla aplikacji i testu."""
    database = Database(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(database.engine)
    return database
