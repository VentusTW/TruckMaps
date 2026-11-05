"""Przejazdy pojazdu i jego statystyki (podstawa M13).

Po zakończeniu nawigacji aplikacja zapisuje przejazd: km przejechane według GPS, czas,
kto jechał i szacowany koszt trasy. Statystyki pojazdu to sumy przejazdów w miesiącach
(km, godziny, liczba przejazdów, kierowcy, koszt w każdej walucie). Każdy, kto widzi
pojazd, widzi jego statystyki; zapisuje ten, kto może nim jechać.
"""

import uuid
from collections import defaultdict
from datetime import UTC, datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field, model_validator
from sqlalchemy import DateTime, ForeignKey, String, select, update
from sqlalchemy.orm import Mapped, Session, mapped_column

from truckmaps.core.db import Base, get_session
from truckmaps.core.i18n import t
from truckmaps.core.vehicles import (
    DRIVABLE,
    VehicleKind,
    VehicleProfile,
    load_owned,
    person_names,
)
from truckmaps.sdk import Principal

MAX_TRIP_KM = 3000
MAX_TRIP_HOURS = 48


class VehicleTrip(Base):
    __tablename__ = "vehicle_trips"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    vehicle_id: Mapped[str] = mapped_column(
        ForeignKey("vehicle_profiles.id", ondelete="CASCADE"), index=True
    )
    driver: Mapped[str] = mapped_column(String(255))
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    ended_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    distance_km: Mapped[float]
    planned_km: Mapped[float | None]
    cost_amount: Mapped[float | None]
    cost_currency: Mapped[str | None] = mapped_column(String(3))
    loaded: Mapped[bool | None]
    """Z ładunkiem (``False`` – pusty przejazd; ``None`` – nie podano)."""
    idle_min: Mapped[float | None]
    """Przestoje w czasie jazdy (pojazd stał z włączoną nawigacją) [min]."""
    trailer_id: Mapped[str | None] = mapped_column(String(36), index=True)
    """Naczepa / przyczepa podpięta w czasie przejazdu."""


class TripIn(BaseModel):
    started_at: datetime
    ended_at: datetime
    distance_km: float = Field(ge=0, le=MAX_TRIP_KM, description="Przejechane według GPS")
    planned_km: float | None = Field(default=None, ge=0, le=MAX_TRIP_KM)
    cost_amount: float | None = Field(default=None, ge=0, le=10_000_000)
    cost_currency: str | None = Field(default=None, pattern="^[A-Z]{3}$")
    loaded: bool | None = Field(default=None, description="Z ładunkiem; False – pusty przejazd")
    idle_min: float | None = Field(default=None, ge=0, le=MAX_TRIP_HOURS * 60)

    @model_validator(mode="after")
    def _times(self) -> "TripIn":
        if self.ended_at < self.started_at or self.ended_at - self.started_at > timedelta(
            hours=MAX_TRIP_HOURS
        ):
            raise ValueError(t("error.trip_times"))
        return self


class Month(BaseModel):
    month: str
    """RRRR-MM."""
    trips: int
    distance_km: float
    hours: float
    drivers: int
    costs: dict[str, float]
    """Waluta → szacowany koszt tras."""


class Share(BaseModel):
    """Część przejazdów: kierowca albo naczepa / pojazd ciągnący."""

    id: str
    name: str
    trips: int
    distance_km: float


class Period(BaseModel):
    """Poprzedni okres tej samej długości – do porównania."""

    trips: int
    distance_km: float
    hours: float
    costs: dict[str, float]


class VehicleStats(BaseModel):
    vehicle_id: str
    trips: int
    distance_km: float
    hours: float
    drivers: int
    costs: dict[str, float]
    cost_per_km: dict[str, float]
    months: list[Month]
    first_trip: datetime | None
    last_trip: datetime | None
    empty_km: float
    """Puste km (przejazdy oznaczone „bez ładunku”)."""
    empty_share: float | None
    """Część pustych km wśród przejazdów z podanym ładunkiem (0–1); ``None`` – nie podano."""
    idle_hours: float
    by_driver: list[Share]
    linked: list[Share]
    """Pojazd: naczepy / przyczepy, z którymi jeździł; naczepa: pojazdy, które ją ciągnęły."""
    previous: Period | None = None


def _aware(value: datetime) -> datetime:
    return value if value.tzinfo else value.replace(tzinfo=UTC)


def move_trips(db: Session, kept_id: str, merged_id: str) -> None:
    """Scalenie dubla pojazdu: przejazdy przechodzą na zachowany pojazd."""
    db.execute(
        update(VehicleTrip).where(VehicleTrip.vehicle_id == merged_id).values(vehicle_id=kept_id)
    )
    db.execute(
        update(VehicleTrip).where(VehicleTrip.trailer_id == merged_id).values(trailer_id=kept_id)
    )


def stats(
    trips: list[VehicleTrip],
    vehicle_id: str,
    names: dict[str, str] | None = None,
    vehicle_names: dict[str, str] | None = None,
    towed: bool = False,
) -> VehicleStats:
    months: dict[str, list[VehicleTrip]] = defaultdict(list)
    for trip in trips:
        months[f"{_aware(trip.started_at):%Y-%m}"].append(trip)

    def costs(items: list[VehicleTrip]) -> dict[str, float]:
        found: dict[str, float] = defaultdict(float)
        for trip in items:
            if trip.cost_amount is not None and trip.cost_currency:
                found[trip.cost_currency] += trip.cost_amount
        return {c: round(v, 2) for c, v in found.items()}

    def hours(items: list[VehicleTrip]) -> float:
        seconds = sum((_aware(i.ended_at) - _aware(i.started_at)).total_seconds() for i in items)
        return round(seconds / 3600, 1)

    km = round(sum(t.distance_km for t in trips), 1)
    # Koszt na km tylko z przejazdów, które mają koszt (bez stawek koszt nie jest liczony).
    per_km = {}
    for currency, amount in costs(trips).items():
        priced = sum(t.distance_km for t in trips if t.cost_currency == currency)
        if priced:
            per_km[currency] = round(amount / priced, 3)
    starts = [_aware(t.started_at) for t in trips]
    names, vehicle_names = names or {}, vehicle_names or {}
    known = [t for t in trips if t.loaded is not None]
    empty = sum(t.distance_km for t in known if not t.loaded)
    known_km = sum(t.distance_km for t in known)

    def shares(key, label) -> list[Share]:
        groups: dict[str, list[VehicleTrip]] = defaultdict(list)
        for trip in trips:
            if (value := key(trip)) is not None:
                groups[value].append(trip)
        return sorted(
            (
                Share(
                    id=value, name=label(value), trips=len(items),
                    distance_km=round(sum(i.distance_km for i in items), 1),
                )
                for value, items in groups.items()
            ),
            key=lambda s: -s.distance_km,
        )  # fmt: skip

    return VehicleStats(
        vehicle_id=vehicle_id,
        trips=len(trips),
        distance_km=km,
        hours=hours(trips),
        drivers=len({t.driver for t in trips}),
        costs=costs(trips),
        cost_per_km=per_km,
        months=[
            Month(
                month=month,
                trips=len(items),
                distance_km=round(sum(i.distance_km for i in items), 1),
                hours=hours(items),
                drivers=len({i.driver for i in items}),
                costs=costs(items),
            )
            for month, items in sorted(months.items(), reverse=True)
        ],
        first_trip=min(starts, default=None),
        last_trip=max(starts, default=None),
        empty_km=round(empty, 1),
        empty_share=round(empty / known_km, 3) if known_km else None,
        idle_hours=round(sum(t.idle_min or 0 for t in trips) / 60, 1),
        by_driver=shares(lambda t: t.driver, lambda s: names.get(s, s[-6:])),
        linked=shares(
            (lambda t: t.vehicle_id) if towed else (lambda t: t.trailer_id),
            lambda v: vehicle_names.get(v, "–"),
        ),
    )


def _period(trips: list[VehicleTrip]) -> Period:
    full = stats(trips, "")
    return Period(
        trips=full.trips, distance_km=full.distance_km, hours=full.hours, costs=full.costs
    )


def build_router(current_user) -> APIRouter:
    router = APIRouter(prefix="/api/vehicles", tags=["vehicles"])
    User = Annotated[Principal, Depends(current_user)]
    Db = Annotated[Session, Depends(get_session)]

    @router.post("/{vehicle_id}/trips", status_code=status.HTTP_201_CREATED)
    def add_trip(vehicle_id: str, data: TripIn, user: User, db: Db) -> dict:
        """Przejazd po zakończeniu nawigacji – kierowca, który jechał tym pojazdem."""
        vehicle = load_owned(db, vehicle_id, user)
        if VehicleKind(vehicle.kind) not in DRIVABLE:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_CONTENT, t("error.vehicle_not_drivable")
            )
        trip = VehicleTrip(
            vehicle_id=vehicle.id, driver=user.subject, trailer_id=vehicle.trailer_id,
            **data.model_dump(),
        )  # fmt: skip
        db.add(trip)
        db.commit()
        return {"id": trip.id}

    @router.get("/{vehicle_id}/stats")
    def vehicle_stats(vehicle_id: str, user: User, db: Db, months: int = 12) -> VehicleStats:
        """Statystyki z przejazdów w ostatnich ``months`` miesiącach (1–36) i porównanie
        z poprzednim okresem tej samej długości. Naczepa / przyczepa – przejazdy, w których
        była podpięta."""
        vehicle = load_owned(db, vehicle_id, user)
        towed = VehicleKind(vehicle.kind) not in DRIVABLE
        span = timedelta(days=31 * max(1, min(months, 36)))
        now = datetime.now(UTC)
        column = VehicleTrip.trailer_id if towed else VehicleTrip.vehicle_id
        trips = list(
            db.scalars(
                select(VehicleTrip).where(
                    column == vehicle.id, VehicleTrip.started_at >= now - span
                )
            )
        )
        before = list(
            db.scalars(
                select(VehicleTrip).where(
                    column == vehicle.id,
                    VehicleTrip.started_at >= now - 2 * span,
                    VehicleTrip.started_at < now - span,
                )
            )
        )
        other_ids = {t.vehicle_id if towed else t.trailer_id for t in trips} - {None}
        vehicle_names = {
            v.id: v.name
            for v in db.scalars(select(VehicleProfile).where(VehicleProfile.id.in_(other_ids)))
        } if other_ids else {}  # fmt: skip
        names = person_names(db, {t.driver for t in trips}, vehicle.company_id)
        result = stats(trips, vehicle.id, names, vehicle_names, towed)
        result.previous = _period(before) if before else None
        return result

    return router
