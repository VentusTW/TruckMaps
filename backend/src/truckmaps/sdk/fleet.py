"""Pojazdy i baza danych dla modułów – bez sięgania do wnętrza rdzenia."""

from collections.abc import Callable, Iterator
from dataclasses import dataclass
from datetime import date
from typing import Protocol

from sqlalchemy.orm import Session

from truckmaps.sdk.auth import Principal

PRIVATE = "private"
"""„Rola” przy pojeździe prywatnym: jego właściciel."""

SERVICE_ROLES = frozenset({"owner", "dispatcher", "mechanic", PRIVATE})
"""Kto obsługuje pojazd (przegląd, naprawa): właściciel, dyspozytor, mechanik albo właściciel
pojazdu prywatnego."""


@dataclass(frozen=True)
class VehicleInfo:
    """Pojazd widoczny dla użytkownika i jego rola przy nim."""

    id: str
    name: str
    plate: str | None
    kind: str
    company_id: str | None
    role: str
    """Rola w firmie pojazdu (owner, dispatcher, mechanic, driver) albo ``private``."""
    in_repair: bool = False


class Fleet(Protocol):
    def vehicles(self, db: Session, user: Principal) -> list[VehicleInfo]:
        """Pojazdy prywatne użytkownika i pojazdy jego firm."""
        ...

    def vehicle(self, db: Session, user: Principal, vehicle_id: str) -> VehicleInfo | None:
        """Pojazd, jeśli użytkownik go widzi; inaczej ``None``."""
        ...

    def set_in_repair(self, db: Session, vehicle_id: str, in_repair: bool) -> None:
        """Pojazd „w naprawie” – niedostępny do jazdy (zapis razem z sesją modułu)."""
        ...

    def set_repair_reported(self, db: Session, vehicle_id: str, reported: bool) -> None:
        """Zgłoszona usterka, pojazd może jechać (zapis razem z sesją modułu)."""
        ...

    def on_vehicles_merged(self, handler: Callable[[Session, str, str], None]) -> None:
        """Administrator scala zdublowane pojazdy: ``handler(db, kept_id, merged_id)`` przenosi
        dane modułu na zachowany pojazd – w tej samej sesji, przed usunięciem dubla."""
        ...

    def record_inspection(self, db: Session, vehicle_id: str, day: date, valid_until: date) -> None:
        """Przegląd techniczny zrobiony w serwisie: ostatni przegląd i nowa ważność pojazdu."""
        ...


class Storage(Protocol):
    @property
    def session(self) -> Callable[..., Iterator[Session]]:
        """Zależność FastAPI z sesją bazy: ``db: Annotated[Session, Depends(ctx.storage.session)]``.

        Tabele modułu: własny ``DeclarativeBase`` i własne migracje Alembica (gałąź modułu).
        """
        ...
