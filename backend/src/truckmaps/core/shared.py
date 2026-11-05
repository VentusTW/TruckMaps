"""Dokumenty udostępniane krótkim linkiem (np. protokół naprawy do druku).

Moduł zapisuje gotowy dokument (``ctx.storage.share``) i dostaje adres z losowym kluczem,
ważny kilka minut. Aplikacja otwiera go w przeglądarce systemu – także na telefonie, gdzie
plik z pamięci aplikacji nie otworzy się w przeglądarce. Adres nie wymaga logowania (klucz
jest nie do odgadnięcia i wygasa), dlatego udostępnia się tylko to, co użytkownik i tak widzi.
"""

import secrets
from datetime import UTC, datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import DateTime, LargeBinary, String, delete
from sqlalchemy.orm import Mapped, Session, mapped_column

from truckmaps.core.db import Base, get_session
from truckmaps.core.i18n import t

MAX_MINUTES = 60
MAX_BYTES = 20 * 1024 * 1024


class SharedDocument(Base):
    __tablename__ = "shared_documents"

    token: Mapped[str] = mapped_column(String(64), primary_key=True)
    content_type: Mapped[str] = mapped_column(String(100))
    filename: Mapped[str] = mapped_column(String(200))
    body: Mapped[bytes] = mapped_column(LargeBinary)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)


def _now() -> datetime:
    return datetime.now(UTC)


def share(db: Session, body: bytes, content_type: str, filename: str, minutes: int = 15) -> str:
    """Zapisuje dokument i zwraca jego adres (``/api/shared/<klucz>``); stare wygasłe usuwa."""
    if len(body) > MAX_BYTES:
        raise ValueError("document too large")
    db.execute(delete(SharedDocument).where(SharedDocument.expires_at < _now()))
    token = secrets.token_urlsafe(32)
    db.add(
        SharedDocument(
            token=token,
            content_type=content_type,
            filename=filename[:200],
            body=body,
            expires_at=_now() + timedelta(minutes=max(1, min(minutes, MAX_MINUTES))),
        )
    )
    db.commit()
    return f"/api/shared/{token}"


def build_router() -> APIRouter:
    router = APIRouter(tags=["shared"])

    @router.get("/api/shared/{token}")
    def shared_document(token: str, db: Annotated[Session, Depends(get_session)]) -> Response:
        document = db.get(SharedDocument, token)
        expires = document and document.expires_at
        if expires is not None and expires.tzinfo is None:
            expires = expires.replace(tzinfo=UTC)  # SQLite (testy) – daty bez strefy
        if document is None or expires < _now():
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("error.shared_expired"))
        return Response(
            document.body,
            media_type=document.content_type,
            headers={
                "Content-Disposition": f'inline; filename="{document.filename}"',
                "Cache-Control": "no-store",
                "X-Robots-Tag": "noindex",
            },
        )

    return router
