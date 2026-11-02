"""Przypomnienia o terminach pojazdów w skrzynce wiadomości.

30 dni przed terminem „ważny do” (albo od razu, gdy już minął) i 2000 km przed serwisem
według przebiegu. Każdy termin przypominamy raz – nowa data albo nowy przebieg serwisu to
nowy termin. Pojazd firmy: właściciel, dyspozytorzy i mechanicy; prywatny: jego właściciel.
Treść składa aplikacja z danych wiadomości, w języku użytkownika.
"""

import logging
import threading
from collections.abc import Iterator
from datetime import date, datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from truckmaps.core import inbox
from truckmaps.core.db import Database
from truckmaps.core.fleet import service_staff
from truckmaps.core.timebans import HOME_ZONE
from truckmaps.core.vehicles import ServiceDates, VehicleProfile

log = logging.getLogger(__name__)

DUE_SOON_DAYS = 30
SERVICE_SOON_KM = 2000
CHECK_EVERY_S = 6 * 3600
DATE_FIELDS = [name for name in ServiceDates.model_fields if name.endswith("_until")]


def due(vehicle: VehicleProfile, today: date) -> Iterator[tuple[str, str, dict]]:
    """Terminy do przypomnienia: (pole, znacznik terminu, dane wiadomości)."""
    for field in DATE_FIELDS:
        day = getattr(vehicle, field)
        if day is not None and (day - today).days <= DUE_SOON_DAYS:
            yield field, day.isoformat(), {"day": day.isoformat(), "overdue": day < today}
    if vehicle.odometer_km is not None and vehicle.service_due_km is not None:
        left = vehicle.service_due_km - vehicle.odometer_km
        if left <= SERVICE_SOON_KM:
            data = {"km_left": left, "overdue": left < 0}
            yield "service_due_km", str(vehicle.service_due_km), data


def send_reminders(db: Session, today: date | None = None) -> int:
    """Wysyła nowe przypomnienia; zwraca liczbę wiadomości."""
    today = today or datetime.now(HOME_ZONE).date()
    count = 0
    for vehicle in db.scalars(select(VehicleProfile)):
        sent = dict(vehicle.reminders_sent or {})
        new = [item for item in due(vehicle, today) if sent.get(item[0]) != item[1]]
        if not new:
            continue
        to = service_staff(db, vehicle)
        for field, mark, data in new:
            inbox.send(
                db,
                to,
                inbox.Kind.VEHICLE_DUE,
                sender_name="",
                company_id=vehicle.company_id,
                data={
                    "vehicle_id": vehicle.id,
                    "vehicle_name": vehicle.name,
                    "plate": vehicle.plate,
                    "field": field,
                    **data,
                },
            )
            sent[field] = mark
            count += len(to)
        vehicle.reminders_sent = sent
    db.commit()
    return count


class ReminderSender:
    """Wątek w tle: przypomnienia przy starcie serwera i potem co kilka godzin."""

    def __init__(self, database: Database) -> None:
        self._database = database
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, name="przypomnienia", daemon=True)

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                with self._database.session() as db:
                    if sent := send_reminders(db):
                        log.info("Przypomnienia o terminach pojazdów: %d", sent)
            except Exception as exc:  # noqa: BLE001 – błąd nie może zatrzymać serwera
                log.warning("Nie udało się wysłać przypomnień: %s", exc)
            self._stop.wait(CHECK_EVERY_S)
