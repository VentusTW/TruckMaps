"""Baza danych rdzenia (PostgreSQL/PostGIS; w testach SQLite)."""

from collections.abc import Iterator
from typing import Any

from fastapi import HTTPException, Request, status
from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker


class Base(DeclarativeBase):
    """Tabele rdzenia. Moduły będą miały własne schematy i migracje."""


class Database:
    def __init__(self, url: str, **engine_options: Any) -> None:
        self.engine = create_engine(url, pool_pre_ping=True, **engine_options)
        self._sessions = sessionmaker(self.engine, expire_on_commit=False)

    def session(self) -> Session:
        return self._sessions()


def get_session(request: Request) -> Iterator[Session]:
    """Zależność FastAPI: sesja bazy na czas jednego żądania."""
    database: Database | None = request.app.state.database
    if database is None:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE, "Baza danych nie jest skonfigurowana."
        )
    with database.session() as session:
        yield session
