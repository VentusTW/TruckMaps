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


@dataclass(frozen=True)
class CargoInfo:
    """Przestrzeń ładunkowa i ładowność pojazdu z profilu (do planu załadunku)."""

    deck_length_m: float | None
    """Z miejsc paletowych (33 palety EUR = 13,6 m); ``None`` – nie wiadomo."""
    payload_kg: float | None
    """DMC − masa własna; ``None`` – brak masy własnej."""
    kind: str = ""
    """Rodzaj pojazdu (semitrailer, rigid, trailer, van, combination) – do nacisków na osie."""
    axle_count: int | None = None
    axle_load_t: float | None = None
    """Dopuszczalny nacisk pojedynczej osi z profilu."""
    tare_kg: float | None = None
    gvw_kg: float | None = None
    height_m: float | None = None
    """Wysokość całkowita pojazdu – z niej szacunkowa wysokość przestrzeni ładunkowej."""
    kingpin_m: float | None = None
    """Naczepa: sworzeń od przodu (z dokumentów); ``None`` – typowa geometria."""
    axles_m: float | None = None
    """Naczepa / przyczepa: środek zespołu osi od przodu."""
    wheelbase_m: float | None = None
    """Solówka: rozstaw osi (przednia – środek tylnych)."""


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

    def cargo(self, db: Session, vehicle_id: str) -> CargoInfo:
        """Przestrzeń ładunkowa i ładowność pojazdu (bez sprawdzania widoczności)."""
        ...

    def staff(self, db: Session, vehicle_id: str) -> list[str]:
        """Kto obsługuje pojazd: właściciel, dyspozytorzy i mechanicy firmy albo właściciel
        pojazdu prywatnego (identyfikatory kont)."""
        ...

    def notify(
        self, db: Session, recipients: list[str], kind: str, data: dict, company_id: str | None
    ) -> None:
        """Wiadomość w skrzynce aplikacji (zapis razem z sesją modułu). Treść składa aplikacja
        z ``kind`` i ``data`` w języku odbiorcy – ``kind`` z przedrostkiem id modułu."""
        ...


class Storage(Protocol):
    @property
    def session(self) -> Callable[..., Iterator[Session]]:
        """Zależność FastAPI z sesją bazy: ``db: Annotated[Session, Depends(ctx.storage.session)]``.

        Tabele modułu: własny ``DeclarativeBase`` i własne migracje Alembica (gałąź modułu).
        """
        ...

    def share(
        self, db: Session, body: bytes, content_type: str, filename: str, minutes: int = 15
    ) -> str:
        """Dokument pod krótkim linkiem bez logowania (``/api/shared/<klucz>``, do 60 min) –
        np. protokół do otwarcia w przeglądarce telefonu. Tylko to, co użytkownik i tak widzi."""
        ...
