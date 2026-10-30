"""Waluty: kursy EBC i przeliczanie kwot, waluta wybrana przez użytkownika.

Kursy referencyjne Europejskiego Banku Centralnego są darmowe i publikowane raz dziennie
w dni robocze (ok. 16:00 CET), jako liczba jednostek waluty za 1 euro. Trzymamy je w bazie
z datą kursu – gdy EBC jest nieosiągalny, przeliczamy po ostatnim znanym kursie.

Kwota zawsze idzie w parze z kodem waluty (ISO 4217); euro nie jest walutą domyślnie
zakładaną, tylko walutą bazową kursów.
"""

import logging
import threading
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends
from pydantic import AfterValidator, BaseModel, Field, StringConstraints
from sqlalchemy import Boolean, Date, String, func, select, update
from sqlalchemy.orm import Mapped, Session, mapped_column

from truckmaps.core.config import ECB_URL
from truckmaps.core.db import Base, Database, get_session
from truckmaps.core.i18n import t
from truckmaps.sdk import Principal
from truckmaps.sdk.i18n import languages

log = logging.getLogger(__name__)

REFRESH_EVERY_S = 6 * 3600
FETCH_TIMEOUT_S = 20

# Waluty do wyboru (kolejność listy w aplikacji): kraje, w których jeżdżą nasi kierowcy,
# i najczęstsze waluty rozliczeń. Wszystkie są w kursach EBC.
CURRENCIES = ("PLN", "EUR", "CZK", "HUF", "RON", "DKK", "SEK", "NOK", "CHF", "GBP", "TRY", "USD")
"""Nazwy walut: teksty ``currency.<kod>``."""
BASE = "EUR"


def _known(code: str) -> str:
    code = code.strip().upper()
    if code not in CURRENCIES:
        raise ValueError(t("error.unsupported_currency", code=code, codes=", ".join(CURRENCIES)))
    return code


Currency = Annotated[str, AfterValidator(_known), Field(examples=["PLN"])]


class ExchangeRate(Base):
    __tablename__ = "exchange_rates"

    day: Mapped[date] = mapped_column(Date, primary_key=True)
    currency: Mapped[str] = mapped_column(String(3), primary_key=True)
    per_eur: Mapped[float]
    """Ile jednostek waluty za 1 euro."""


class UserSettings(Base):
    """Ustawienia konta trzymane u nas (konto i logowanie są u dostawcy logowania)."""

    __tablename__ = "user_settings"

    subject: Mapped[str] = mapped_column(String(255), primary_key=True)
    currency: Mapped[str | None] = mapped_column(String(3))
    display_name: Mapped[str | None] = mapped_column(String(200))
    """Jak widzą cię członkowie firm; brak = imię z konta logowania."""
    language: Mapped[str | None] = mapped_column(String(5))
    """Język aplikacji; brak = język telefonu."""
    onboarded: Mapped[bool] = mapped_column(Boolean, default=False, server_default="false")
    """Pierwsze logowanie za nami: firma założona, dołączenie kodem albo „sam, bez firmy”."""


@dataclass(frozen=True)
class Rates:
    day: date | None = None
    """Data kursu EBC; ``None`` – brak kursów (np. pierwsze uruchomienie bez internetu)."""
    per_eur: dict[str, float] = field(default_factory=dict)

    def convert(self, amount: float, source: str, target: str) -> float | None:
        """Kwota w walucie ``target``; ``None``, gdy brak kursu którejś z walut."""
        if source == target:
            return amount
        rates = {**self.per_eur, BASE: 1.0}
        if source not in rates or target not in rates:
            return None
        return amount / rates[source] * rates[target]


def latest_rates(db: Session) -> Rates:
    day = db.scalar(select(func.max(ExchangeRate.day)))
    if day is None:
        return Rates()
    rows = db.scalars(select(ExchangeRate).where(ExchangeRate.day == day))
    return Rates(day=day, per_eur={r.currency: r.per_eur for r in rows})


def parse_ecb(xml: bytes) -> tuple[date, dict[str, float]]:
    """Plik ``eurofxref-daily.xml``: ``<Cube time="…"><Cube currency="PLN" rate="4.25"/>…``."""
    root = ET.fromstring(xml)
    for cube in root.iter():
        if cube.tag.endswith("Cube") and "time" in cube.attrib:
            rates = {
                c.attrib["currency"]: float(c.attrib["rate"])
                for c in cube
                if "currency" in c.attrib and "rate" in c.attrib
            }
            if rates:
                return date.fromisoformat(cube.attrib["time"]), rates
    raise ValueError("Brak kursów w odpowiedzi EBC.")


def store_rates(db: Session, day: date, rates: dict[str, float]) -> bool:
    """Zapisuje kursy z danego dnia; ``False``, gdy już były."""
    if db.scalar(select(ExchangeRate.day).where(ExchangeRate.day == day).limit(1)):
        return False
    db.add_all(ExchangeRate(day=day, currency=c, per_eur=r) for c, r in rates.items())
    db.commit()
    return True


def refresh_rates(database: Database, url: str = ECB_URL) -> date:
    with urllib.request.urlopen(url, timeout=FETCH_TIMEOUT_S) as response:  # noqa: S310
        day, rates = parse_ecb(response.read())
    with database.session() as db:
        if store_rates(db, day, rates):
            log.info("Kursy EBC z %s zapisane (%d walut)", day, len(rates))
    return day


class RateUpdater:
    """Wątek w tle: kursy EBC przy starcie serwera i potem co kilka godzin."""

    def __init__(self, database: Database, url: str) -> None:
        self._database, self._url = database, url
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, name="kursy-ebc", daemon=True)

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                refresh_rates(self._database, self._url)
            except Exception as exc:  # noqa: BLE001 – brak sieci nie może zatrzymać serwera
                log.warning("Nie udało się pobrać kursów EBC: %s", exc)
            self._stop.wait(REFRESH_EVERY_S)


def user_currency(db: Session, user: Principal) -> str | None:
    settings = db.get(UserSettings, user.subject)
    return settings.currency if settings else None


class CurrencyOut(BaseModel):
    code: str
    name: str


class CurrenciesOut(BaseModel):
    currencies: list[CurrencyOut]
    rates_day: date | None
    """Data kursu EBC używanego do przeliczeń."""
    per_eur: dict[str, float]


def _language(code: str) -> str:
    code = code.strip().lower()
    if code not in languages():
        raise ValueError(t("error.unsupported_language", code=code, codes=", ".join(languages())))
    return code


class SettingsIn(BaseModel):
    """Ustawienia konta; zmieniane są tylko pola podane w zapytaniu."""

    currency: Currency | None = Field(
        default=None, description="Waluta kosztów; brak = waluta firmy pojazdu albo jego stawek"
    )
    display_name: (
        Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)]
        | None
    ) = Field(default=None, description="Jak widzą cię członkowie firm")
    language: Annotated[str, AfterValidator(_language)] | None = Field(
        default=None, examples=["pl"], description="Język aplikacji; brak = język telefonu"
    )
    onboarded: bool = False


class SettingsOut(SettingsIn):
    display_name: str = ""
    """Ustawione imię albo imię z konta logowania."""


def display_name(user: Principal, settings: UserSettings | None = None) -> str:
    """Imię widoczne dla innych: ustawione w koncie, z konta logowania albo z końcówki konta."""
    claims = user.claims
    name = settings.display_name if settings else None
    name = name or claims.get("name") or claims.get("email") or claims.get("preferred_username")
    return (name or t("account.user_fallback", id=user.subject[-6:])).strip()[:200]


def _settings_out(user: Principal, settings: UserSettings | None) -> SettingsOut:
    return SettingsOut(
        currency=settings.currency if settings else None,
        display_name=display_name(user, settings),
        language=settings.language if settings else None,
        onboarded=bool(settings and settings.onboarded),
    )


def build_router(current_user) -> APIRouter:
    router = APIRouter(tags=["currency"])
    User = Annotated[Principal, Depends(current_user)]
    Db = Annotated[Session, Depends(get_session)]

    @router.get("/api/currencies")
    def currencies(user: User, db: Db) -> CurrenciesOut:
        rates = latest_rates(db)
        return CurrenciesOut(
            currencies=[CurrencyOut(code=c, name=t(f"currency.{c}")) for c in CURRENCIES],
            rates_day=rates.day,
            per_eur={c: r for c, r in rates.per_eur.items() if c in CURRENCIES},
        )

    @router.get("/api/me/settings")
    def get_settings(user: User, db: Db) -> SettingsOut:
        return _settings_out(user, db.get(UserSettings, user.subject))

    @router.put("/api/me/settings")
    def put_settings(data: SettingsIn, user: User, db: Db) -> SettingsOut:
        settings = db.get(UserSettings, user.subject) or UserSettings(subject=user.subject)
        for name, value in data.model_dump(exclude_unset=True).items():
            setattr(settings, name, value)
        db.add(settings)
        if "display_name" in data.model_fields_set:
            # Nowe imię widać od razu we wszystkich firmach użytkownika.
            members = Base.metadata.tables["company_members"]
            db.execute(
                update(members)
                .where(members.c.subject == user.subject)
                .values(display_name=display_name(user, settings))
            )
        db.commit()
        return _settings_out(user, settings)

    return router
