"""Powiadomienia e-mail o nowych wiadomościach w skrzynce.

Bezkosztowo: zwykły serwer SMTP (własny albo darmowe konto pocztowe), ustawiany zmiennymi
``TRUCKMAPS_SMTP_*``; bez nich nic nie wysyłamy. Użytkownik włącza powiadomienia sam
w ustawieniach konta – adres bierzemy wtedy z konta logowania. Wiadomość ma tytuł w języku
użytkownika i odsyła do aplikacji; szczegóły (dane firmy, pojazdu) zostają w aplikacji.
"""

import logging
import smtplib
import threading
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from email.message import EmailMessage

from sqlalchemy import select
from sqlalchemy.orm import Session

from truckmaps.core.currency import UserSettings
from truckmaps.core.db import Database
from truckmaps.core.i18n import t, use
from truckmaps.core.inbox import Message

log = logging.getLogger(__name__)

CHECK_EVERY_S = 60
MAX_AGE = timedelta(hours=1)
"""Starszych wiadomości nie wysyłamy (np. po włączeniu powiadomień albo przerwie serwera)."""


@dataclass(frozen=True)
class SmtpSettings:
    host: str
    port: int = 587
    user: str | None = None
    password: str | None = None
    sender: str = "TruckMaps <noreply@truckmaps.localhost>"
    starttls: bool = True


def compose(message: Message, address: str, sender: str) -> EmailMessage:
    data = {k: v for k, v in (message.data or {}).items() if isinstance(v, str | int | float)}
    key = f"inbox.{message.kind}"
    try:
        title = t(key, **data)
    except (KeyError, IndexError):  # tekst z parametrem, którego wiadomość nie ma
        title = key
    if title == key:
        title = t("inbox.generic")
    mail = EmailMessage()
    mail["From"], mail["To"] = sender, address
    mail["Subject"] = t("email.subject", title=title)
    mail.set_content(t("email.body", title=title))
    return mail


def pending(db: Session, now: datetime) -> list[tuple[Message, UserSettings]]:
    rows = db.execute(
        select(Message, UserSettings)
        .join(UserSettings, UserSettings.subject == Message.recipient)
        .where(
            Message.emailed_at.is_(None),
            Message.read_at.is_(None),
            Message.created_at >= now - MAX_AGE,
            UserSettings.email_notifications.is_(True),
            UserSettings.email.is_not(None),
        )
        .order_by(Message.created_at)
        .limit(100)
    )
    return list(rows.tuples())


def send_pending(db: Session, smtp: SmtpSettings, now: datetime | None = None) -> int:
    """Wysyła zaległe powiadomienia; zwraca liczbę wysłanych."""
    now = now or datetime.now(UTC)
    items = pending(db, now)
    if not items:
        return 0
    sent = 0
    with smtplib.SMTP(smtp.host, smtp.port, timeout=30) as server:
        if smtp.starttls:
            server.starttls()
        if smtp.user:
            server.login(smtp.user, smtp.password or "")
        for message, settings in items:
            with use(settings.language or "pl"):
                server.send_message(compose(message, settings.email, smtp.sender))
            message.emailed_at = now
            sent += 1
    db.commit()
    return sent


class MailSender:
    """Wątek w tle: co minutę wysyła powiadomienia o nowych wiadomościach."""

    def __init__(self, database: Database, smtp: SmtpSettings) -> None:
        self._database, self._smtp = database, smtp
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, name="powiadomienia-email", daemon=True)

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                with self._database.session() as db:
                    if sent := send_pending(db, self._smtp):
                        log.info("Powiadomienia e-mail: %d", sent)
            except Exception as exc:  # noqa: BLE001 – serwer poczty nie może zatrzymać serwera
                log.warning("Nie udało się wysłać powiadomień e-mail: %s", exc)
            self._stop.wait(CHECK_EVERY_S)
