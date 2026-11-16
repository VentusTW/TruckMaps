"""Kierowcy firmy: kartoteka, kwalifikacje z terminami, przydział do pojazdów, przejazdy.

Kierowca może mieć konto (członek firmy) albo być tylko wpisem w kartotece. Kartotekę
prowadzą właściciel i dyspozytorzy; kierowca z kontem widzi swoją kartę. Terminy (prawo jazdy,
kod 95, badania, karta kierowcy i pobranie z niej danych, ADR, świadectwo kierowcy) trafiają
jako przypomnienia do skrzynki: 30 dni przed (pobranie z karty – 7 dni) i po terminie.
Przy przydziale do pojazdu i przy wyznaczaniu trasy moduł ostrzega, gdy kierowcy brakuje
kategorii prawa jazdy, zaświadczenia ADR albo ważnych badań (gniazdo ``DRIVER_CHECK``).
Przydział kierowcy z kontem to przydział rdzenia (``assigned_driver``); moduł zapisuje
historię przydziałów (od–do) i zmian w kartotece. Korzysta tylko z SDK rdzenia.
"""

import base64
import binascii
import json
import re
import uuid
from collections import defaultdict
from datetime import UTC, date, datetime, timedelta
from importlib import resources
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Response, status
from pydantic import BaseModel, ConfigDict, Field, field_validator
from sqlalchemy import (
    JSON,
    Date,
    DateTime,
    Float,
    Integer,
    LargeBinary,
    String,
    Text,
    UniqueConstraint,
    delete,
    func,
    select,
    update,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column

from truckmaps.sdk import (
    DASHBOARD_FEED,
    DRIVER_CHECK,
    CoreContext,
    DashboardAlert,
    DashboardKpi,
    DashboardPart,
    Module,
    Principal,
    TripInfo,
    i18n,
)
from truckmaps.sdk.i18n import t
from truckmaps_drivers import hours, rules, tacho

MANAGERS = {"owner", "dispatcher"}
MAX_TRIPS_SHOWN = 50
MAX_TACHO_BYTES = 20 * 1024 * 1024
TACHO_DAYS = 28


def _now() -> datetime:
    return datetime.now(UTC)


def _aware(value: datetime) -> datetime:
    return value if value.tzinfo else value.replace(tzinfo=UTC)


class Base(DeclarativeBase):
    """Tabele modułu – osobno od rdzenia, z własną gałęzią migracji (``drivers``)."""


class Driver(Base):
    __tablename__ = "drivers"
    __table_args__ = (UniqueConstraint("company_id", "subject"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    company_id: Mapped[str] = mapped_column(String(36), index=True)
    subject: Mapped[str | None] = mapped_column(String(255), index=True)
    """Konto kierowcy (członek firmy); ``None`` – wpis bez konta."""
    name: Mapped[str] = mapped_column(String(200))
    phone: Mapped[str | None] = mapped_column(String(40))
    email: Mapped[str | None] = mapped_column(String(200))
    hired_on: Mapped[date | None] = mapped_column(Date)
    notes: Mapped[str | None] = mapped_column(Text)
    license_categories: Mapped[list] = mapped_column(JSON, default=list)
    license_until: Mapped[date | None] = mapped_column(Date)
    code95_until: Mapped[date | None] = mapped_column(Date)
    """Kwalifikacja wstępna / szkolenie okresowe (kod 95) – co 5 lat."""
    medical_until: Mapped[date | None] = mapped_column(Date)
    psych_until: Mapped[date | None] = mapped_column(Date)
    card_until: Mapped[date | None] = mapped_column(Date)
    """Karta kierowcy (tachograf) – ważna 5 lat."""
    card_downloaded_on: Mapped[date | None] = mapped_column(Date)
    card_download_until: Mapped[date | None] = mapped_column(Date)
    card_number: Mapped[str | None] = mapped_column(String(20))
    """Numer karty kierowcy – z pliku .DDD (łączy dane z tachografów pojazdów)."""
    """Pobranie danych z karty – co najmniej co 28 dni."""
    adr_until: Mapped[date | None] = mapped_column(Date)
    adr_tank: Mapped[bool] = mapped_column(default=False)
    """Zaświadczenie ADR obejmuje przewóz w cysternach."""
    attestation_until: Mapped[date | None] = mapped_column(Date)
    """Świadectwo kierowcy (kierowca spoza UE)."""
    reminders_sent: Mapped[dict | None] = mapped_column(JSON)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class Assignment(Base):
    """Przydział kierowcy do pojazdu: od – do (``None`` – trwa)."""

    __tablename__ = "driver_assignments"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    driver_id: Mapped[str] = mapped_column(String(36), index=True)
    vehicle_id: Mapped[str] = mapped_column(String(36), index=True)
    vehicle_name: Mapped[str] = mapped_column(String(130), default="")
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    by_name: Mapped[str] = mapped_column(String(200), default="")


class Change(Base):
    """Historia kartoteki: kto, kiedy i co zmienił."""

    __tablename__ = "driver_changes"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    driver_id: Mapped[str] = mapped_column(String(36), index=True)
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    by_subject: Mapped[str] = mapped_column(String(255), default="")
    by_name: Mapped[str] = mapped_column(String(200), default="")
    action: Mapped[str] = mapped_column(String(20))
    """created, updated, assigned, released, card_download."""
    changes: Mapped[dict] = mapped_column(JSON, default=dict)
    """Pole → [przed, po] (tekst); przydział – pojazd."""


class TachoDownload(Base):
    """Wczytany plik .DDD (karta kierowcy albo tachograf pojazdu) – w całości, do archiwum."""

    __tablename__ = "tacho_downloads"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    company_id: Mapped[str] = mapped_column(String(36), index=True)
    kind: Mapped[str] = mapped_column(String(10))
    """card albo vu."""
    generation: Mapped[int] = mapped_column(Integer, default=1)
    driver_id: Mapped[str | None] = mapped_column(String(36), index=True)
    vehicle_id: Mapped[str | None] = mapped_column(String(36), index=True)
    name: Mapped[str] = mapped_column(String(200))
    card_number: Mapped[str | None] = mapped_column(String(20))
    holder_name: Mapped[str | None] = mapped_column(String(200))
    vin: Mapped[str | None] = mapped_column(String(17))
    plate: Mapped[str | None] = mapped_column(String(20))
    period_start: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    period_end: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    activities: Mapped[int] = mapped_column(Integer, default=0)
    size: Mapped[int] = mapped_column(Integer, default=0)
    content: Mapped[bytes] = mapped_column(LargeBinary)
    by_name: Mapped[str] = mapped_column(String(200), default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class TachoActivity(Base):
    """Odcinek aktywności kierowcy (UTC) z karty albo z tachografu pojazdu."""

    __tablename__ = "tacho_activities"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    company_id: Mapped[str] = mapped_column(String(36), index=True)
    download_id: Mapped[str] = mapped_column(String(36), index=True)
    source: Mapped[str] = mapped_column(String(10))
    driver_id: Mapped[str | None] = mapped_column(String(36), index=True)
    vehicle_id: Mapped[str | None] = mapped_column(String(36), index=True)
    card_number: Mapped[str] = mapped_column(String(20), default="")
    start: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
    end: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    activity: Mapped[str] = mapped_column(String(12))
    slot: Mapped[int] = mapped_column(Integer, default=0)
    crew: Mapped[bool] = mapped_column(default=False)
    manual: Mapped[bool] = mapped_column(default=False)


class TachoPlace(Base):
    """Miejsce rozpoczęcia albo zakończenia dziennego okresu pracy."""

    __tablename__ = "tacho_places"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    company_id: Mapped[str] = mapped_column(String(36), index=True)
    download_id: Mapped[str] = mapped_column(String(36), index=True)
    source: Mapped[str] = mapped_column(String(10))
    driver_id: Mapped[str | None] = mapped_column(String(36), index=True)
    vehicle_id: Mapped[str | None] = mapped_column(String(36), index=True)
    card_number: Mapped[str] = mapped_column(String(20), default="")
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
    entry: Mapped[str] = mapped_column(String(10))
    country: Mapped[str] = mapped_column(String(4), default="")
    region: Mapped[int] = mapped_column(Integer, default=0)
    odometer: Mapped[int] = mapped_column(Integer, default=0)
    lat: Mapped[float | None] = mapped_column(Float)
    lon: Mapped[float | None] = mapped_column(Float)


EDITABLE = [
    "name",
    "phone",
    "email",
    "hired_on",
    "notes",
    "license_categories",
    "adr_tank",
    "card_downloaded_on",
    *rules.DATE_FIELDS,
]


class DriverIn(BaseModel):
    name: str = Field(min_length=2, max_length=200, examples=["Jan Kowalski"])
    phone: str | None = Field(default=None, max_length=40)
    email: str | None = Field(default=None, max_length=200, pattern=r"^[^@\s]+@[^@\s]+$")
    hired_on: date | None = None
    notes: str | None = Field(default=None, max_length=4000)
    member_id: str | None = Field(default=None, description="Konto kierowcy (członek firmy)")
    license_categories: list[str] = Field(default_factory=list, max_length=10)
    license_until: date | None = None
    code95_until: date | None = Field(default=None, description="Kod 95 – co 5 lat")
    medical_until: date | None = None
    psych_until: date | None = None
    card_until: date | None = Field(default=None, description="Karta kierowcy – co 5 lat")
    card_downloaded_on: date | None = None
    card_download_until: date | None = Field(
        default=None, description="Brak – 28 dni od ostatniego pobrania"
    )
    adr_until: date | None = None
    adr_tank: bool = False
    attestation_until: date | None = Field(default=None, description="Świadectwo kierowcy")

    @field_validator("license_categories")
    @classmethod
    def _categories(cls, value: list[str]) -> list[str]:
        upper = [c.strip().upper().replace("+", "") for c in value]
        if unknown := [c for c in upper if c not in rules.CATEGORIES]:
            raise ValueError(t("drivers.unknown_category", value=", ".join(unknown)))
        return [c for c in rules.CATEGORIES if c in upper]


class NewDriverIn(DriverIn):
    company_id: str


class VehicleRef(BaseModel):
    vehicle_id: str
    name: str
    plate: str | None = None
    since: datetime


class Due(BaseModel):
    field: str
    day: date
    state: str
    """ok, soon, overdue."""


class DriverOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    company_id: str
    name: str
    phone: str | None
    email: str | None
    hired_on: date | None
    notes: str | None
    has_account: bool = False
    member_id: str | None = None
    member_name: str | None = None
    license_categories: list[str]
    license_until: date | None
    code95_until: date | None
    medical_until: date | None
    psych_until: date | None
    card_until: date | None
    card_downloaded_on: date | None
    card_download_until: date | None
    card_number: str | None = None
    adr_until: date | None
    adr_tank: bool
    attestation_until: date | None
    vehicles: list[VehicleRef] = []
    dues: list[Due] = []
    can_edit: bool = False
    updated_at: datetime


class TachoUploadIn(BaseModel):
    company_id: str
    name: str = Field(min_length=1, max_length=200, examples=["C_20261114_1012_J_KOWALSKI.DDD"])
    data: str = Field(description="Zawartość pliku w base64")
    driver_id: str | None = Field(default=None, description="Kierowca (plik karty)")
    vehicle_id: str | None = Field(default=None, description="Pojazd (plik tachografu)")


class TachoDownloadOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    kind: str
    generation: int
    driver_id: str | None
    vehicle_id: str | None
    name: str
    card_number: str | None
    holder_name: str | None
    vin: str | None
    plate: str | None
    period_start: datetime | None
    period_end: datetime | None
    activities: int
    size: int
    by_name: str
    created_at: datetime


class TachoUploadOut(TachoDownloadOut):
    driver_name: str | None = None
    unmatched_cards: list[str] = []
    """Karty z tachografu pojazdu bez kierowcy w kartotece (numer – posiadacz)."""


class TachoSegmentOut(BaseModel):
    start: datetime
    end: datetime
    activity: str
    source: str
    manual: bool = False


class TachoPlaceOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    at: datetime
    entry: str
    country: str
    odometer: int
    lat: float | None
    lon: float | None


class ViolationOut(BaseModel):
    kind: str
    severity: str
    start: datetime
    end: datetime
    value: float
    limit: float


class CountersOut(BaseModel):
    at: datetime | None = None
    continuous_driving: float = 0
    continuous_limit: float = hours.CONTINUOUS_DRIVING
    daily_driving: float = 0
    daily_limit: float = hours.EXTENDED_DRIVING
    extensions_left: int = hours.EXTENSIONS_PER_WEEK
    daily_rest_due: datetime | None = None
    reduced_rests_left: int = hours.REDUCED_DAILY_PER_WEEK
    weekly_driving: float = 0
    weekly_limit: float = hours.WEEKLY_DRIVING
    fortnight_driving: float = 0
    fortnight_limit: float = hours.FORTNIGHT_DRIVING
    weekly_rest_due: datetime | None = None
    last_weekly_rest: datetime | None = None


class TachoOut(BaseModel):
    driver_id: str
    card_number: str | None
    days: int
    segments: list[TachoSegmentOut]
    violations: list[ViolationOut]
    counters: CountersOut
    places: list[TachoPlaceOut]
    downloads: list[TachoDownloadOut]


class ComplianceDriverOut(BaseModel):
    driver_id: str
    name: str
    has_data: bool
    """Czy są dane tachografu (karta albo pojazd)."""
    violations: int
    serious: int
    """Naruszenia poważne (``serious``)."""
    very_serious: int
    last_violation: datetime | None
    card_downloaded_on: date | None
    card_download_until: date | None
    dues_soon: int = 0
    """Terminy dokumentów kierowcy (prawo jazdy, badania, karta…) wkrótce."""
    dues_overdue: int = 0


class ComplianceOut(BaseModel):
    """Naruszenia 561/2006 kierowców firmy z ostatnich ``days`` dni danych tachografu."""

    days: int
    drivers: list[ComplianceDriverOut]


class VehicleTachoOut(BaseModel):
    vehicle_id: str
    last_download: datetime | None
    downloads: list[TachoDownloadOut]


def _card_key(number: str | None) -> str:
    """Numer karty bez indeksów wymiany i odnowienia (ostatnie 2 znaki)."""
    return (number or "").strip().upper()[:14]


def _plate_key(plate: str | None) -> str:
    return re.sub(r"[^0-9A-Z]", "", (plate or "").upper())


def tacho_view(
    driver_id: str,
    card_number: str | None,
    rows: list,
    places: list,
    downloads: list,
    days: int = TACHO_DAYS,
) -> TachoOut:
    """Odcinki z karty mają pierwszeństwo; z tachografu pojazdu – tylko dni bez danych karty."""
    card_days = {_aware(r.start).date() for r in rows if r.source == "card"}
    used = [r for r in rows if r.source == "card" or _aware(r.start).date() not in card_days]
    used.sort(key=lambda r: _aware(r.start))
    analysis = hours.analyse(
        [hours.Segment(_aware(r.start), _aware(r.end), r.activity) for r in used]
    )
    since = None
    if used:
        last = max(_aware(r.end) for r in used)
        since = datetime.combine(last.date() - timedelta(days=days - 1), datetime.min.time(), UTC)
    return TachoOut(
        driver_id=driver_id,
        card_number=card_number,
        days=days,
        segments=[
            TachoSegmentOut(
                start=_aware(r.start), end=_aware(r.end), activity=r.activity, source=r.source,
                manual=r.manual,
            )
            for r in used
            if since is None or _aware(r.end) > since
        ],
        violations=[
            ViolationOut(**v.__dict__)
            for v in analysis.violations
            if since is None or v.end > since
        ],
        counters=CountersOut(**analysis.counters.__dict__),
        places=[
            TachoPlaceOut.model_validate(p)
            for p in places
            if since is None or _aware(p.at) >= since
        ],
        downloads=[TachoDownloadOut.model_validate(d) for d in downloads],
    )  # fmt: skip


class AssignIn(BaseModel):
    vehicle_id: str


class AssignOut(BaseModel):
    driver: DriverOut
    warnings: list[str]


class AssignmentOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    vehicle_id: str
    vehicle_name: str
    started_at: datetime
    ended_at: datetime | None
    by_name: str


class ChangeOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    at: datetime
    by_name: str
    action: str
    changes: dict


class CandidateOut(BaseModel):
    member_id: str
    name: str
    role: str


class MonthStats(BaseModel):
    month: str
    trips: int
    distance_km: float
    hours: float
    empty_km: float
    idle_hours: float


class VehicleShare(BaseModel):
    vehicle_id: str
    name: str
    trips: int
    distance_km: float


class TripOut(BaseModel):
    id: str
    vehicle_id: str
    vehicle_name: str
    started_at: datetime
    ended_at: datetime
    distance_km: float
    loaded: bool | None
    idle_min: float | None


class DriverStats(BaseModel):
    driver_id: str
    trips: int
    distance_km: float
    hours: float
    empty_km: float
    idle_hours: float
    vehicles: int
    costs: dict[str, float]
    months: list[MonthStats]
    by_vehicle: list[VehicleShare]
    recent: list[TripOut]


def _hours(items: list[TripInfo]) -> float:
    seconds = sum((_aware(i.ended_at) - _aware(i.started_at)).total_seconds() for i in items)
    return round(seconds / 3600, 1)


def _empty(items: list[TripInfo]) -> float:
    return round(sum(i.distance_km for i in items if i.loaded is False), 1)


def _idle(items: list[TripInfo]) -> float:
    return round(sum(i.idle_min or 0 for i in items) / 60, 1)


def driver_stats(driver_id: str, trips: list[TripInfo]) -> DriverStats:
    months: dict[str, list[TripInfo]] = defaultdict(list)
    vehicles: dict[str, list[TripInfo]] = defaultdict(list)
    costs: dict[str, float] = defaultdict(float)
    for trip in trips:
        months[f"{_aware(trip.started_at):%Y-%m}"].append(trip)
        vehicles[trip.vehicle_id].append(trip)
        if trip.cost_amount is not None and trip.cost_currency:
            costs[trip.cost_currency] += trip.cost_amount
    return DriverStats(
        driver_id=driver_id,
        trips=len(trips),
        distance_km=round(sum(t.distance_km for t in trips), 1),
        hours=_hours(trips),
        empty_km=_empty(trips),
        idle_hours=_idle(trips),
        vehicles=len(vehicles),
        costs={c: round(v, 2) for c, v in costs.items()},
        months=[
            MonthStats(
                month=month, trips=len(items),
                distance_km=round(sum(i.distance_km for i in items), 1),
                hours=_hours(items), empty_km=_empty(items), idle_hours=_idle(items),
            )
            for month, items in sorted(months.items(), reverse=True)
        ],
        by_vehicle=sorted(
            (
                VehicleShare(
                    vehicle_id=vehicle_id, name=items[0].vehicle_name, trips=len(items),
                    distance_km=round(sum(i.distance_km for i in items), 1),
                )
                for vehicle_id, items in vehicles.items()
            ),
            key=lambda s: -s.distance_km,
        ),
        recent=[
            TripOut(
                id=t.id, vehicle_id=t.vehicle_id, vehicle_name=t.vehicle_name,
                started_at=t.started_at, ended_at=t.ended_at, distance_km=t.distance_km,
                loaded=t.loaded, idle_min=t.idle_min,
            )
            for t in trips[:MAX_TRIPS_SHOWN]
        ],
    )  # fmt: skip


def _text(value: object) -> str | None:
    if value is None:
        return None
    if isinstance(value, list):
        return ", ".join(str(v) for v in value)
    return str(value)


def _user_name(user: Principal) -> str:
    claims = user.claims
    return str(claims.get("name") or claims.get("email") or user.subject[-6:])[:200]


class DriversModule(Module):
    id = "drivers"
    name = "Kierowcy"
    version = "0.1.0"
    requires_core = ">=0.1,<1.0"

    def register(self, ctx: CoreContext) -> None:
        for file in (resources.files("truckmaps_drivers") / "locales").iterdir():
            if file.name.endswith(".json"):
                i18n.register(file.name.removesuffix(".json"), json.loads(file.read_text("utf-8")))

        router = APIRouter()
        User = Annotated[Principal, Depends(ctx.auth.current_user)]
        Db = Annotated[Session, Depends(ctx.storage.session)]
        fleet = ctx.fleet

        def today() -> date:
            return datetime.now(UTC).date()

        def roles(db: Session, company_id: str) -> dict[str, tuple[str, str, str]]:
            """Konto → (id członka, imię, rola)."""
            return {m.subject: (m.id, m.name, m.role) for m in fleet.members(db, company_id)}

        def role(db: Session, user: Principal, company_id: str) -> str | None:
            found = roles(db, company_id).get(user.subject)
            return found[2] if found else None

        def load(db: Session, user: Principal, driver_id: str, *, edit: bool = False) -> Driver:
            """Karta kierowcy dla obsługi firmy; kierowca widzi tylko swoją (404 dla obcych)."""
            driver = db.get(Driver, driver_id)
            current = role(db, user, driver.company_id) if driver else None
            own = driver is not None and driver.subject == user.subject and current is not None
            if driver is None or (current not in MANAGERS and not own):
                raise HTTPException(status.HTTP_404_NOT_FOUND, t("drivers.not_found"))
            if edit and current not in MANAGERS:
                raise HTTPException(status.HTTP_403_FORBIDDEN, t("drivers.edit_forbidden"))
            return driver

        def open_assignments(db: Session, driver_ids: list[str]) -> list[Assignment]:
            return list(
                db.scalars(
                    select(Assignment).where(
                        Assignment.driver_id.in_(driver_ids), Assignment.ended_at.is_(None)
                    )
                )
            )

        def close_vehicle(db: Session, vehicle_id: str, keep: str | None = None) -> None:
            """Kończy trwające przydziały pojazdu (oprócz kierowcy ``keep``)."""
            query = update(Assignment).where(
                Assignment.vehicle_id == vehicle_id, Assignment.ended_at.is_(None)
            )
            if keep:
                query = query.where(Assignment.driver_id != keep)
            db.execute(query.values(ended_at=_now()))

        def sync(db: Session, company_id: str) -> None:
            """Przydziały kierowców z kontem według rdzenia (mógł je zmienić np. przed instalacją
            modułu) – brakujące otwiera, nieaktualne zamyka."""
            assigned = fleet.assigned(db, company_id)
            drivers = list(
                db.scalars(
                    select(Driver).where(
                        Driver.company_id == company_id, Driver.subject.is_not(None)
                    )
                )
            )
            if not drivers:
                return
            by_subject = {d.subject: d for d in drivers}
            current = open_assignments(db, [d.id for d in drivers])
            have = {(a.driver_id, a.vehicle_id) for a in current}
            wanted = {(by_subject[s].id, v) for v, s in assigned.items() if s in by_subject}
            for item in current:
                if (item.driver_id, item.vehicle_id) not in wanted:
                    item.ended_at = _now()
            for driver_id, vehicle_id in wanted - have:
                info = fleet.driving(db, vehicle_id)
                close_vehicle(db, vehicle_id)
                db.add(
                    Assignment(
                        driver_id=driver_id, vehicle_id=vehicle_id,
                        vehicle_name=info.name if info else "",
                    )
                )  # fmt: skip
            db.flush()

        def outs(db: Session, user: Principal, drivers: list[Driver]) -> list[DriverOut]:
            people: dict[str, dict] = {}
            for company_id in {d.company_id for d in drivers}:
                people[company_id] = roles(db, company_id)
            vehicles: dict[str, list[VehicleRef]] = defaultdict(list)
            for item in open_assignments(db, [d.id for d in drivers]):
                info = fleet.driving(db, item.vehicle_id)
                if info is not None:
                    vehicles[item.driver_id].append(
                        VehicleRef(
                            vehicle_id=info.vehicle_id, name=info.name, plate=info.plate,
                            since=item.started_at,
                        )
                    )  # fmt: skip
            day = today()
            result = []
            for driver in drivers:
                members = people[driver.company_id]
                member = members.get(driver.subject) if driver.subject else None
                mine = members.get(user.subject)
                result.append(
                    DriverOut.model_validate(driver).model_copy(
                        update={
                            "has_account": member is not None,
                            "member_id": member[0] if member else None,
                            "member_name": member[1] if member else None,
                            "vehicles": vehicles.get(driver.id, []),
                            "dues": [
                                Due(field=f, day=d, state=s) for f, d, s in rules.dues(driver, day)
                            ],
                            "can_edit": mine is not None and mine[2] in MANAGERS,
                        }
                    )
                )
            return result

        def log(db: Session, driver: Driver, user: Principal | None, action: str, changes: dict):
            db.add(
                Change(
                    driver_id=driver.id, action=action, changes=changes,
                    by_subject=user.subject if user else "",
                    by_name=_user_name(user) if user else "",
                )
            )  # fmt: skip

        def apply(db: Session, driver: Driver, data: DriverIn) -> dict:
            """Zapisuje pola karty; zwraca zmiany (pole → [przed, po])."""
            values = data.model_dump(include=set(EDITABLE))
            if data.card_downloaded_on and not data.card_download_until:
                values["card_download_until"] = data.card_downloaded_on + timedelta(
                    days=rules.CARD_DOWNLOAD_DAYS
                )
            changes = {}
            for field, value in values.items():
                before = getattr(driver, field)
                if before != value:
                    changes[field] = [_text(before), _text(value)]
                    setattr(driver, field, value)
            members = {m.id: m for m in fleet.members(db, driver.company_id)}
            subject = None
            if data.member_id:
                member = members.get(data.member_id)
                if member is None:
                    raise HTTPException(
                        status.HTTP_422_UNPROCESSABLE_CONTENT, t("drivers.member_not_found")
                    )
                subject = member.subject
            if subject != driver.subject:
                taken = db.scalar(
                    select(Driver).where(
                        Driver.company_id == driver.company_id,
                        Driver.subject == subject,
                        Driver.id != driver.id,
                    )
                )
                if subject and taken is not None:
                    raise HTTPException(status.HTTP_409_CONFLICT, t("drivers.member_taken"))
                old = {m.subject: m.name for m in members.values()}
                changes["account"] = [old.get(driver.subject or ""), old.get(subject or "")]
                release_all(db, driver)
                driver.subject = subject
            return changes

        def release_all(db: Session, driver: Driver) -> None:
            """Kończy przydziały kierowcy (także w rdzeniu – zmiana konta albo usunięcie)."""
            for item in open_assignments(db, [driver.id]):
                item.ended_at = _now()
                info = fleet.driving(db, item.vehicle_id)
                # Otwarty przydział tego kierowcy = on jest kierowcą pojazdu (także bez konta).
                if info and info.assigned_driver == driver.subject:
                    fleet.assign_driver(db, item.vehicle_id, None)

        # ── Kartoteka ──────────────────────────────────────────────────────────────────────

        @router.get("/drivers")
        def list_drivers(user: User, db: Db, company_id: str | None = None) -> list[DriverOut]:
            """Kierowcy firm, w których użytkownik jest właścicielem albo dyspozytorem,
            i jego własna karta kierowcy."""
            query = select(Driver).order_by(Driver.name)
            if company_id:
                query = query.where(Driver.company_id == company_id)
            found = []
            managed: dict[str, bool] = {}
            for driver in db.scalars(query):
                if driver.company_id not in managed:
                    managed[driver.company_id] = role(db, user, driver.company_id) in MANAGERS
                own = driver.subject == user.subject
                if managed[driver.company_id] or own:
                    found.append(driver)
            for company in {d.company_id for d in found}:
                sync(db, company)
            db.commit()
            return outs(db, user, found)

        @router.post("/drivers", status_code=status.HTTP_201_CREATED)
        def add_driver(data: NewDriverIn, user: User, db: Db) -> DriverOut:
            current = role(db, user, data.company_id)
            if current is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, t("drivers.company_not_found"))
            if current not in MANAGERS:
                raise HTTPException(status.HTTP_403_FORBIDDEN, t("drivers.edit_forbidden"))
            driver = Driver(company_id=data.company_id, name=data.name, license_categories=[])
            apply(db, driver, data)
            db.add(driver)
            db.flush()
            log(db, driver, user, "created", {})
            db.flush()
            sync(db, driver.company_id)
            db.commit()
            return outs(db, user, [driver])[0]

        @router.get("/drivers/{driver_id}")
        def get_driver(driver_id: str, user: User, db: Db) -> DriverOut:
            driver = load(db, user, driver_id)
            sync(db, driver.company_id)
            db.commit()
            return outs(db, user, [driver])[0]

        @router.put("/drivers/{driver_id}")
        def update_driver(driver_id: str, data: DriverIn, user: User, db: Db) -> DriverOut:
            driver = load(db, user, driver_id, edit=True)
            changes = apply(db, driver, data)
            if changes:
                driver.updated_at = _now()
                log(db, driver, user, "updated", changes)
            db.flush()
            sync(db, driver.company_id)
            db.commit()
            return outs(db, user, [driver])[0]

        @router.delete("/drivers/{driver_id}", status_code=status.HTTP_204_NO_CONTENT)
        def delete_driver(driver_id: str, user: User, db: Db) -> Response:
            """Usuwa kartę z historią przydziałów i zmian; zwalnia pojazdy kierowcy."""
            driver = load(db, user, driver_id, edit=True)
            release_all(db, driver)
            db.execute(delete(Assignment).where(Assignment.driver_id == driver.id))
            db.execute(delete(Change).where(Change.driver_id == driver.id))
            db.execute(delete(TachoActivity).where(TachoActivity.driver_id == driver.id))
            db.execute(delete(TachoPlace).where(TachoPlace.driver_id == driver.id))
            db.execute(
                update(TachoDownload)
                .where(TachoDownload.driver_id == driver.id)
                .values(driver_id=None)
            )
            db.delete(driver)
            db.commit()
            return Response(status_code=status.HTTP_204_NO_CONTENT)

        @router.get("/candidates")
        def candidates(company_id: str, user: User, db: Db) -> list[CandidateOut]:
            """Konta firmy bez karty kierowcy – do połączenia z kartą (najpierw kierowcy)."""
            if role(db, user, company_id) not in MANAGERS:
                raise HTTPException(status.HTTP_404_NOT_FOUND, t("drivers.company_not_found"))
            linked = set(db.scalars(select(Driver.subject).where(Driver.company_id == company_id)))
            members = [m for m in fleet.members(db, company_id) if m.subject not in linked]
            members.sort(key=lambda m: (m.role != "driver", m.name))
            return [CandidateOut(member_id=m.id, name=m.name, role=m.role) for m in members]

        @router.post("/drivers/{driver_id}/card-download")
        def card_downloaded(driver_id: str, user: User, db: Db) -> DriverOut:
            """Pobrano dziś dane z karty kierowcy – następne za 28 dni (może też kierowca)."""
            driver = load(db, user, driver_id)
            day = today()
            before = _text(driver.card_downloaded_on)
            driver.card_downloaded_on = day
            driver.card_download_until = day + timedelta(days=rules.CARD_DOWNLOAD_DAYS)
            driver.updated_at = _now()
            log(db, driver, user, "card_download", {"card_downloaded_on": [before, _text(day)]})
            db.commit()
            return outs(db, user, [driver])[0]

        # ── Tachograf (.DDD) ───────────────────────────────────────────────────────────────

        def company_driver(db: Session, company_id: str, driver_id: str) -> Driver:
            driver = db.get(Driver, driver_id)
            if driver is None or driver.company_id != company_id:
                raise HTTPException(status.HTTP_404_NOT_FOUND, t("drivers.not_found"))
            return driver

        def replace(db: Session, table, column, value, source: str, start, end) -> None:
            """Usuwa wcześniej wczytane dane z tego samego okresu (ponowny odczyt karty)."""
            if start is None or end is None:
                return
            moment = table.start if table is TachoActivity else table.at
            db.execute(
                delete(table).where(
                    column == value, table.source == source, moment >= start, moment < end
                )
            )

        def matched_vehicle(db: Session, user: Principal, data: TachoUploadIn, parsed):
            vehicles = [v for v in fleet.vehicles(db, user) if v.company_id == data.company_id]
            if data.vehicle_id:
                vehicle = next((v for v in vehicles if v.id == data.vehicle_id), None)
                if vehicle is None:
                    raise HTTPException(status.HTTP_404_NOT_FOUND, t("drivers.vehicle_not_found"))
                return vehicle
            key = _plate_key(parsed.plate)
            vehicle = next((v for v in vehicles if key and _plate_key(v.plate) == key), None)
            if vehicle is None:
                raise HTTPException(
                    status.HTTP_422_UNPROCESSABLE_CONTENT,
                    t("tacho.choose_vehicle", plate=parsed.plate or "–", vin=parsed.vin or "–"),
                )
            return vehicle

        @router.post("/tacho/upload", status_code=status.HTTP_201_CREATED)
        def tacho_upload(data: TachoUploadIn, user: User, db: Db) -> TachoUploadOut:
            """Wczytuje plik .DDD z karty kierowcy albo z tachografu pojazdu: aktywności,
            miejsca, data pobrania (karta – następne za 28 dni, pojazd – za 90 dni). Pliki
            pojazdu i cudze karty wczytuje obsługa firmy; kierowca – swoją kartę."""
            current = role(db, user, data.company_id)
            if current is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, t("drivers.company_not_found"))
            try:
                content = base64.b64decode(data.data.split(",")[-1], validate=True)
            except (binascii.Error, ValueError) as error:
                raise HTTPException(
                    status.HTTP_422_UNPROCESSABLE_CONTENT, t("tacho.not_ddd")
                ) from error
            if len(content) > MAX_TACHO_BYTES:
                raise HTTPException(status.HTTP_413_CONTENT_TOO_LARGE, t("tacho.too_large", mb=20))
            try:
                parsed = tacho.parse(content)
            except tacho.TachoError as error:
                raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, t(error.code)) from error
            drivers = list(db.scalars(select(Driver).where(Driver.company_id == data.company_id)))
            by_card = {_card_key(d.card_number): d for d in drivers if d.card_number}
            day = today()
            record = TachoDownload(
                company_id=data.company_id, kind=parsed.kind, generation=parsed.generation,
                name=data.name, card_number=parsed.card_number[:20] or None,
                holder_name=parsed.holder_name[:200] or None, vin=parsed.vin[:17] or None,
                plate=parsed.plate[:20] or None, period_start=parsed.period_start,
                period_end=parsed.period_end, activities=len(parsed.activities), size=len(content),
                content=content, by_name=_user_name(user),
            )  # fmt: skip
            driver: Driver | None = None
            unmatched: list[str] = []
            if parsed.kind == "card":
                if data.driver_id:
                    driver = company_driver(db, data.company_id, data.driver_id)
                else:
                    driver = by_card.get(_card_key(parsed.card_number))
                if driver is None:
                    raise HTTPException(
                        status.HTTP_422_UNPROCESSABLE_CONTENT,
                        t("tacho.choose_driver", name=parsed.holder_name, card=parsed.card_number),
                    )
                if current not in MANAGERS and driver.subject != user.subject:
                    raise HTTPException(status.HTTP_403_FORBIDDEN, t("tacho.forbidden"))
                owner = by_card.get(_card_key(parsed.card_number))
                if owner is not None and owner.id != driver.id:
                    raise HTTPException(
                        status.HTTP_409_CONFLICT, t("tacho.card_taken", name=owner.name)
                    )
                before = _text(driver.card_downloaded_on)
                driver.card_number = parsed.card_number[:20] or driver.card_number
                driver.card_downloaded_on = day
                driver.card_download_until = day + timedelta(days=rules.CARD_DOWNLOAD_DAYS)
                if parsed.card_expiry and not driver.card_until:
                    driver.card_until = parsed.card_expiry
                driver.updated_at = _now()
                log(db, driver, user, "card_download", {"card_downloaded_on": [before, _text(day)]})
                record.driver_id = driver.id
                db.add(record)
                db.flush()
                for table in (TachoActivity, TachoPlace):
                    replace(
                        db, table, table.driver_id, driver.id, "card", parsed.period_start,
                        parsed.period_end,
                    )  # fmt: skip
            else:
                if current not in MANAGERS:
                    raise HTTPException(status.HTTP_403_FORBIDDEN, t("tacho.forbidden"))
                vehicle = matched_vehicle(db, user, data, parsed)
                fleet.record_tacho_download(db, vehicle.id, day)
                record.vehicle_id = vehicle.id
                db.add(record)
                db.flush()
                for table in (TachoActivity, TachoPlace):
                    replace(
                        db, table, table.vehicle_id, vehicle.id, "vu", parsed.period_start,
                        parsed.period_end,
                    )  # fmt: skip
                unmatched = sorted(
                    f"{number} – {name}"
                    for number, name in parsed.cards().items()
                    if _card_key(number) not in by_card
                )
            for item in parsed.activities:
                owner = driver or by_card.get(_card_key(item.card_number))
                db.add(
                    TachoActivity(
                        company_id=data.company_id, download_id=record.id, source=parsed.kind,
                        driver_id=owner.id if owner else None, vehicle_id=record.vehicle_id,
                        card_number=item.card_number[:20], start=item.start, end=item.end,
                        activity=item.activity, slot=item.slot, crew=item.crew, manual=item.manual,
                    )
                )  # fmt: skip
            for place in parsed.places:
                owner = driver or by_card.get(_card_key(place.card_number))
                db.add(
                    TachoPlace(
                        company_id=data.company_id, download_id=record.id, source=parsed.kind,
                        driver_id=owner.id if owner else None, vehicle_id=record.vehicle_id,
                        card_number=place.card_number[:20], at=place.at, entry=place.entry,
                        country=place.country, region=place.region, odometer=place.odometer,
                        lat=place.lat, lon=place.lon,
                    )
                )  # fmt: skip
            db.commit()
            return TachoUploadOut.model_validate(record).model_copy(
                update={
                    "driver_name": driver.name if driver else None,
                    "unmatched_cards": unmatched,
                }
            )

        @router.get("/drivers/{driver_id}/tacho")
        def driver_tacho(driver_id: str, user: User, db: Db, days: int = TACHO_DAYS) -> TachoOut:
            """Czas pracy kierowcy z plików .DDD: odcinki aktywności z ostatnich ``days`` dni
            danych, naruszenia 561/2006, liczniki pozostałego czasu jazdy, miejsca, odczyty."""
            return tacho_of(db, load(db, user, driver_id), days)

        def tacho_of(db: Session, driver: Driver, days: int = TACHO_DAYS) -> TachoOut:
            days = max(1, min(days, 366))
            last = db.scalar(
                select(func.max(TachoActivity.end)).where(TachoActivity.driver_id == driver.id)
            )
            rows: list = []
            places: list = []
            if last is not None:
                # Trzy tygodnie wcześniej – limit dwutygodniowy i odpoczynek tygodniowy.
                since = _aware(last) - timedelta(days=days + 21)
                rows = list(
                    db.scalars(
                        select(TachoActivity).where(
                            TachoActivity.driver_id == driver.id, TachoActivity.end > since
                        )
                    )
                )
                places = list(
                    db.scalars(
                        select(TachoPlace)
                        .where(TachoPlace.driver_id == driver.id, TachoPlace.at > since)
                        .order_by(TachoPlace.at)
                    )
                )
            downloads = list(
                db.scalars(
                    select(TachoDownload)
                    .where(TachoDownload.driver_id == driver.id)
                    .order_by(TachoDownload.created_at.desc())
                    .limit(20)
                )
            )
            return tacho_view(driver.id, driver.card_number, rows, places, downloads, days)

        @router.get("/compliance")
        def compliance(
            company_id: str, user: User, db: Db, days: int = TACHO_DAYS
        ) -> ComplianceOut:
            """Zgodność z 561/2006 w firmie: liczba naruszeń każdego kierowcy (z plików .DDD)
            i termin pobrania karty. Tylko właściciel i dyspozytorzy."""
            current = role(db, user, company_id)
            if current is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, t("drivers.company_not_found"))
            if current not in MANAGERS:
                raise HTTPException(status.HTTP_403_FORBIDDEN, t("drivers.edit_forbidden"))
            days = max(1, min(days, 366))
            day = today()
            drivers = list(
                db.scalars(
                    select(Driver).where(Driver.company_id == company_id).order_by(Driver.name)
                )
            )
            # Dwa zapytania dla całej firmy zamiast kilku na kierowcę: koniec danych każdego
            # kierowcy, potem odcinki od najwcześniejszego potrzebnego dnia (jak w tacho_of).
            lasts = {
                driver_id: _aware(last)
                for driver_id, last in db.execute(
                    select(TachoActivity.driver_id, func.max(TachoActivity.end))
                    .where(TachoActivity.driver_id.in_([d.id for d in drivers]))
                    .group_by(TachoActivity.driver_id)
                )
            }
            rows: dict[str, list] = defaultdict(list)
            if lasts:
                earliest = min(lasts.values()) - timedelta(days=days + 21)
                for row in db.scalars(
                    select(TachoActivity).where(
                        TachoActivity.driver_id.in_(list(lasts)), TachoActivity.end > earliest
                    )
                ):
                    if _aware(row.end) > lasts[row.driver_id] - timedelta(days=days + 21):
                        rows[row.driver_id].append(row)
            found = []
            for driver in drivers:
                view = tacho_view(driver.id, driver.card_number, rows[driver.id], [], [], days)
                levels = [v.severity for v in view.violations]
                states = [s for _, _, s in rules.dues(driver, day)]
                found.append(
                    ComplianceDriverOut(
                        driver_id=driver.id,
                        name=driver.name,
                        has_data=bool(view.segments),
                        violations=len(levels),
                        serious=levels.count("serious"),
                        very_serious=levels.count("very_serious"),
                        last_violation=max((v.end for v in view.violations), default=None),
                        card_downloaded_on=driver.card_downloaded_on,
                        card_download_until=driver.card_download_until,
                        dues_soon=states.count("soon"),
                        dues_overdue=states.count("overdue"),
                    )
                )
            return ComplianceOut(days=days, drivers=found)

        @router.get("/tacho/vehicles/{vehicle_id}")
        def vehicle_tacho(vehicle_id: str, user: User, db: Db) -> VehicleTachoOut:
            """Odczyty tachografu pojazdu (ostatni – data pobrania danych z VU)."""
            vehicle = fleet.vehicle(db, user, vehicle_id)
            if vehicle is None or vehicle.company_id is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, t("drivers.vehicle_not_found"))
            downloads = list(
                db.scalars(
                    select(TachoDownload)
                    .where(TachoDownload.vehicle_id == vehicle_id, TachoDownload.kind == "vu")
                    .order_by(TachoDownload.created_at.desc())
                    .limit(20)
                )
            )
            return VehicleTachoOut(
                vehicle_id=vehicle_id,
                last_download=downloads[0].created_at if downloads else None,
                downloads=[TachoDownloadOut.model_validate(d) for d in downloads],
            )

        @router.get("/tacho/downloads/{download_id}/file")
        def tacho_file(download_id: str, user: User, db: Db) -> Response:
            """Oryginalny plik .DDD (archiwum do kontroli)."""
            record = db.get(TachoDownload, download_id)
            current = role(db, user, record.company_id) if record else None
            own = False
            if record is not None and record.driver_id:
                owner = db.get(Driver, record.driver_id)
                own = owner is not None and owner.subject == user.subject
            if record is None or current is None or (current not in MANAGERS and not own):
                raise HTTPException(status.HTTP_404_NOT_FOUND, t("tacho.not_found"))
            safe = re.sub(r"[^0-9A-Za-z._-]", "_", record.name)
            return Response(
                record.content,
                media_type="application/octet-stream",
                headers={"Content-Disposition": f'attachment; filename="{safe}"'},
            )

        # ── Przydział do pojazdów ──────────────────────────────────────────────────────────

        def vehicle_for(db: Session, user: Principal, driver: Driver, vehicle_id: str):
            vehicle = fleet.vehicle(db, user, vehicle_id)
            if vehicle is None or vehicle.company_id != driver.company_id:
                raise HTTPException(status.HTTP_404_NOT_FOUND, t("drivers.vehicle_not_found"))
            info = fleet.driving(db, vehicle_id)
            if info is None or rules.required_category(info) is None:
                raise HTTPException(
                    status.HTTP_422_UNPROCESSABLE_CONTENT, t("drivers.vehicle_not_drivable")
                )
            return info

        @router.get("/drivers/{driver_id}/check")
        def check_vehicle(driver_id: str, vehicle_id: str, user: User, db: Db) -> dict:
            """Ostrzeżenia przed przydziałem: kategoria prawa jazdy, ADR, terminy."""
            driver = load(db, user, driver_id)
            info = vehicle_for(db, user, driver, vehicle_id)
            return {
                "required_category": rules.required_category(info),
                "warnings": rules.problems(driver, info, today()),
            }

        @router.post("/drivers/{driver_id}/assign")
        def assign(driver_id: str, data: AssignIn, user: User, db: Db) -> AssignOut:
            """Przydział do pojazdu (pojazd ma jednego kierowcę – poprzedni przydział się
            kończy); ostrzeżenia nie blokują przydziału."""
            driver = load(db, user, driver_id, edit=True)
            info = vehicle_for(db, user, driver, data.vehicle_id)
            current = {a.vehicle_id for a in open_assignments(db, [driver.id])}
            if data.vehicle_id not in current:
                close_vehicle(db, data.vehicle_id)
                db.add(
                    Assignment(
                        driver_id=driver.id, vehicle_id=info.vehicle_id, vehicle_name=info.name,
                        by_name=_user_name(user),
                    )
                )  # fmt: skip
                log(db, driver, user, "assigned", {"vehicle": [None, info.name]})
            fleet.assign_driver(db, info.vehicle_id, driver.subject, driver.name)
            db.commit()
            return AssignOut(
                driver=outs(db, user, [driver])[0],
                warnings=rules.problems(driver, info, today()),
            )

        @router.post("/drivers/{driver_id}/release")
        def release(driver_id: str, data: AssignIn, user: User, db: Db) -> DriverOut:
            driver = load(db, user, driver_id, edit=True)
            for item in open_assignments(db, [driver.id]):
                if item.vehicle_id == data.vehicle_id:
                    item.ended_at = _now()
                    log(db, driver, user, "released", {"vehicle": [item.vehicle_name, None]})
                    info = fleet.driving(db, item.vehicle_id)
                    if info and info.assigned_driver == driver.subject:
                        fleet.assign_driver(db, item.vehicle_id, None)
            db.commit()
            return outs(db, user, [driver])[0]

        @router.get("/drivers/{driver_id}/assignments")
        def assignments(driver_id: str, user: User, db: Db) -> list[AssignmentOut]:
            driver = load(db, user, driver_id)
            query = select(Assignment).where(Assignment.driver_id == driver.id)
            items = db.scalars(query.order_by(Assignment.started_at.desc()))
            return [AssignmentOut.model_validate(a) for a in items]

        @router.get("/drivers/{driver_id}/history")
        def history(driver_id: str, user: User, db: Db) -> list[ChangeOut]:
            driver = load(db, user, driver_id)
            query = select(Change).where(Change.driver_id == driver.id)
            return [
                ChangeOut.model_validate(c) for c in db.scalars(query.order_by(Change.at.desc()))
            ]

        # ── Przejazdy i statystyki ─────────────────────────────────────────────────────────

        @router.get("/drivers/{driver_id}/stats")
        def stats(driver_id: str, user: User, db: Db, months: int = 12) -> DriverStats:
            """Przejazdy kierowcy w ostatnich ``months`` miesiącach (1–36): z kontem – zapisane
            przez niego pojazdami firmy; bez konta – pojazdów w czasie jego przydziałów."""
            driver = load(db, user, driver_id)
            since = _now() - timedelta(days=31 * max(1, min(months, 36)))
            company = [v.id for v in fleet.vehicles(db, user) if v.company_id == driver.company_id]
            if driver.subject:
                trips = [
                    trip
                    for trip in fleet.trips(db, driver=driver.subject, since=since)
                    if trip.vehicle_id in company
                ]
            else:
                periods = list(
                    db.scalars(select(Assignment).where(Assignment.driver_id == driver.id))
                )
                trips = [
                    trip
                    for trip in fleet.trips(
                        db, vehicle_ids=list({p.vehicle_id for p in periods}), since=since
                    )
                    if any(
                        p.vehicle_id == trip.vehicle_id
                        and _aware(p.started_at) <= _aware(trip.started_at)
                        and (p.ended_at is None or _aware(trip.started_at) < _aware(p.ended_at))
                        for p in periods
                    )
                ]
            return driver_stats(driver.id, trips)

        # ── Powiązania z rdzeniem ──────────────────────────────────────────────────────────

        def driver_assigned(db: Session, vehicle_id: str, subject: str | None, by: Principal):
            """Przydział zmieniony w „Pojazdach” – historia przydziałów nadąża."""
            info = fleet.driving(db, vehicle_id)
            if info is None or info.company_id is None:
                return
            driver = (
                db.scalar(
                    select(Driver).where(
                        Driver.company_id == info.company_id, Driver.subject == subject
                    )
                )
                if subject
                else None
            )
            close_vehicle(db, vehicle_id, keep=driver.id if driver else None)
            if driver is not None and not any(
                a.vehicle_id == vehicle_id for a in open_assignments(db, [driver.id])
            ):
                db.add(
                    Assignment(
                        driver_id=driver.id, vehicle_id=vehicle_id, vehicle_name=info.name,
                        by_name=_user_name(by),
                    )
                )  # fmt: skip
                log(db, driver, by, "assigned", {"vehicle": [None, info.name]})

        def vehicles_merged(db: Session, kept_id: str, merged_id: str) -> None:
            db.execute(
                update(Assignment)
                .where(Assignment.vehicle_id == merged_id)
                .values(vehicle_id=kept_id)
            )
            for table in (TachoDownload, TachoActivity, TachoPlace):
                db.execute(
                    update(table).where(table.vehicle_id == merged_id).values(vehicle_id=kept_id)
                )

        fleet.on_driver_assigned(driver_assigned)
        fleet.on_vehicles_merged(vehicles_merged)

        def reminders(db: Session) -> int:
            """Terminy kierowców w skrzynce: obsługa firmy i sam kierowca (raz przed, raz po)."""
            day = today()
            count = 0
            for driver in db.scalars(select(Driver)):
                sent = dict(driver.reminders_sent or {})
                new = [
                    (field, when, state)
                    for field, when, state in rules.dues(driver, day)
                    if state != "ok" and sent.get(field) != f"{when.isoformat()}:{state}"
                ]
                if not new:
                    continue
                members = fleet.members(db, driver.company_id)
                to = [m.subject for m in members if m.role in MANAGERS]
                if driver.subject and any(m.subject == driver.subject for m in members):
                    to.append(driver.subject)
                for field, when, state in new:
                    data = {
                        "driver_id": driver.id,
                        "driver_name": driver.name,
                        "field": field,
                        "day": when.isoformat(),
                        "overdue": state == "overdue",
                    }
                    fleet.notify(db, sorted(set(to)), "drivers.due", data, driver.company_id)
                    sent[field] = f"{when.isoformat()}:{state}"
                    count += len(set(to))
                driver.reminders_sent = sent
            return count

        ctx.storage.periodic("drivers_reminders", reminders)
        self.send_reminders = reminders

        class Check:
            """Uwagi o kierowcy przed trasą: sam planujący, gdy ma kartę w firmie pojazdu,
            inaczej kierowca przydzielony do pojazdu."""

            def warnings(self, db: Session, user: Principal, vehicle_id: str) -> list[str]:
                info = fleet.driving(db, vehicle_id)
                if info is None or info.company_id is None:
                    return []
                drivers = db.scalars(select(Driver).where(Driver.company_id == info.company_id))
                by_subject = {d.subject: d for d in drivers if d.subject}
                driver = by_subject.get(user.subject)
                if driver is None and info.assigned_driver:
                    driver = by_subject.get(info.assigned_driver)
                if driver is None:
                    driver = db.scalar(
                        select(Driver)
                        .join(Assignment, Assignment.driver_id == Driver.id)
                        .where(Assignment.vehicle_id == vehicle_id, Assignment.ended_at.is_(None))
                    )
                if driver is None:
                    return []
                return [
                    t("drivers.warning", name=driver.name, text=text)
                    for text in rules.problems(driver, info, today())
                ]

        class Feed:
            """Pulpit dyspozytora: kierowcy w pracy i ich terminy (badania, karta, kod 95…)."""

            def collect(self, db: Session, company_id: str, day: date) -> DashboardPart:
                drivers = list(db.scalars(select(Driver).where(Driver.company_id == company_id)))
                active = db.scalars(
                    select(Assignment.driver_id).where(
                        Assignment.driver_id.in_([d.id for d in drivers]),
                        Assignment.ended_at.is_(None),
                    )
                ).all()
                alerts = []
                for driver in drivers:
                    for field, when, state in rules.dues(driver, day):
                        if state == "ok":
                            continue
                        left = (when - day).days
                        severity = (
                            "critical" if state == "overdue" else "warning" if left <= 7 else "info"
                        )
                        alerts.append(
                            DashboardAlert(
                                id=f"drivers:due:{driver.id}:{field}:{when.isoformat()}",
                                kind="drivers.due",
                                severity=severity,
                                data={
                                    "driver_name": driver.name,
                                    "field": field,
                                    "day": when.isoformat(),
                                    "overdue": state == "overdue",
                                },
                                driver_subject=driver.subject,
                                due=when,
                            )
                        )
                overdue = sum(1 for a in alerts if a.severity == "critical")
                return DashboardPart(
                    kpis=[
                        DashboardKpi(
                            key="drivers.assigned",
                            value=len(set(active)),
                            total=len(drivers),
                            order=100,
                        ),
                        DashboardKpi(
                            key="drivers.deadlines",
                            value=len(alerts),
                            tone="error" if overdue else ("warning" if alerts else "ok"),
                            order=110,
                        ),
                    ],
                    alerts=alerts,
                )

        ctx.extensions.provide(DRIVER_CHECK, Check())
        ctx.extensions.provide(DASHBOARD_FEED, Feed())
        ctx.api.include_router(router)
