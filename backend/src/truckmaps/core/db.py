"""Baza danych rdzenia (PostgreSQL/PostGIS; w testach SQLite)."""

from collections.abc import Iterator
from typing import Any

from fastapi import HTTPException, Request, status
from sqlalchemy import create_engine, text
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from truckmaps.core.i18n import t


class Base(DeclarativeBase):
    """Tabele rdzenia. Moduły będą miały własne schematy i migracje."""


def try_job_lock(db: Session, name: str) -> bool:
    """Zadanie w tle tylko na jednej instancji serwera naraz – ``False``: robi je inna.

    PostgreSQL: blokada doradcza do końca bieżącej transakcji (``commit`` / ``rollback``
    ją zwalnia, więc zadanie nie może zatwierdzać zmian w trakcie). Inne bazy (testy na
    SQLite) – zawsze ``True``.
    """
    if db.get_bind().dialect.name != "postgresql":
        return True
    query = text("SELECT pg_try_advisory_xact_lock(hashtext(:name))")
    return bool(db.scalar(query, {"name": f"truckmaps:{name}"}))


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
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, t("error.database_not_configured"))
    with database.session() as session:
        yield session
