"""Skrzynka wiadomości w aplikacji: prośby administratora o dostęp, później wiadomości w firmie.

Serwer zapisuje rodzaj wiadomości i jej dane, a tekst w języku użytkownika składa aplikacja
(z plików tłumaczeń) – ta sama wiadomość czyta się po polsku i po angielsku.
"""

import uuid
from datetime import UTC, datetime
from enum import StrEnum
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import JSON, DateTime, String, func, select
from sqlalchemy.orm import Mapped, Session, mapped_column

from truckmaps.core.db import Base, get_session
from truckmaps.core.i18n import t
from truckmaps.sdk import Principal

INBOX_LIMIT = 100


class Kind(StrEnum):
    ACCESS_REQUEST = "admin_access_request"
    """Administrator prosi o dostęp do zmian (wyróżniona, z przyciskami Zgoda / Odmowa)."""
    EXTENSION_REQUEST = "admin_extension_request"
    ACCESS_CLOSED = "admin_access_closed"
    """Administrator skończył zmiany i zamknął dostęp."""


def _now() -> datetime:
    return datetime.now(UTC)


class Message(Base):
    __tablename__ = "inbox_messages"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    recipient: Mapped[str] = mapped_column(String(255), index=True)
    company_id: Mapped[str | None] = mapped_column(String(36))
    kind: Mapped[str] = mapped_column(String(30))
    sender_name: Mapped[str] = mapped_column(String(200), default="")
    grant_id: Mapped[str | None] = mapped_column(String(36))
    data: Mapped[dict] = mapped_column(JSON, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    read_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


def send(
    db: Session,
    recipients: list[str],
    kind: Kind,
    *,
    sender_name: str,
    company_id: str | None = None,
    grant_id: str | None = None,
    data: dict | None = None,
) -> None:
    for recipient in recipients:
        db.add(
            Message(
                recipient=recipient,
                company_id=company_id,
                kind=kind,
                sender_name=sender_name,
                grant_id=grant_id,
                data=data or {},
            )
        )


def mark_read(db: Session, grant_id: str, recipient: str) -> None:
    """Prośba załatwiona (zgoda, odmowa) – wiadomości o niej przestają być nowe."""
    for message in db.scalars(
        select(Message).where(
            Message.grant_id == grant_id, Message.recipient == recipient, Message.read_at.is_(None)
        )
    ):
        message.read_at = _now()


def build_router(current_user, describe_grant) -> APIRouter:
    """``describe_grant(db, grant_id)`` – stan prośby.

    Aplikacja pokazuje przyciski Zgoda / Odmowa tylko przy prośbie, która jeszcze czeka.
    """
    router = APIRouter(tags=["inbox"])
    User = Annotated[Principal, Depends(current_user)]
    Db = Annotated[Session, Depends(get_session)]

    @router.get("/api/me/messages")
    def messages(user: User, db: Db) -> dict:
        unread = db.scalar(
            select(func.count()).where(Message.recipient == user.subject, Message.read_at.is_(None))
        )
        rows = db.scalars(
            select(Message)
            .where(Message.recipient == user.subject)
            .order_by(Message.created_at.desc())
            .limit(INBOX_LIMIT)
        )
        return {
            "unread": unread,
            "items": [
                {
                    "id": m.id,
                    "kind": m.kind,
                    "sender_name": m.sender_name,
                    "company_id": m.company_id,
                    "grant_id": m.grant_id,
                    "grant": describe_grant(db, m.grant_id) if m.grant_id else None,
                    "data": m.data,
                    "created_at": m.created_at,
                    "read": m.read_at is not None,
                }
                for m in rows
            ],
        }

    @router.post("/api/me/messages/{message_id}/read", status_code=status.HTTP_204_NO_CONTENT)
    def read(message_id: str, user: User, db: Db) -> Response:
        message = db.get(Message, message_id)
        if message is None or message.recipient != user.subject:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("error.message_not_found"))
        if message.read_at is None:
            message.read_at = _now()
            db.commit()
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    return router
