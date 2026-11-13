"""Centrala & Live Map: ostatnie pozycje pojazdów firmy z aplikacji kierowców.

Bez telematyki: pozycję wysyła aplikacja kierowcy w trakcie nawigacji (co ok. 30 s), tylko
dla pojazdów firmy i tylko za zgodą kierowcy (zgoda w aplikacji, na urządzeniu). Serwer trzyma
jedną – ostatnią – pozycję pojazdu, bez historii przejazdu. Właściciel i dyspozytorzy widzą
pojazdy firmy na mapie; pojazd bez nowej pozycji od ``STALE_AFTER`` jest „bez sygnału”.
"""

from datetime import UTC, datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Response, status
from pydantic import BaseModel, Field
from sqlalchemy import DateTime, Float, String, select
from sqlalchemy.orm import Mapped, Session, mapped_column

from truckmaps.core.companies import CompanyMember, Role, membership, require_member
from truckmaps.core.db import Base, get_session
from truckmaps.core.i18n import t
from truckmaps.core.vehicles import VehicleProfile
from truckmaps.sdk import Principal

STALE_AFTER = timedelta(minutes=5)
"""Bez nowej pozycji tak długo – pojazd „bez sygnału” (aplikacja wysyła co ok. 30 s)."""

VIEWERS = {Role.OWNER, Role.DISPATCHER}


def _now() -> datetime:
    return datetime.now(UTC)


def _aware(moment: datetime) -> datetime:
    return moment if moment.tzinfo else moment.replace(tzinfo=UTC)


class VehiclePosition(Base):
    """Ostatnia pozycja pojazdu firmy (jedna na pojazd, nadpisywana)."""

    __tablename__ = "vehicle_positions"

    vehicle_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    company_id: Mapped[str] = mapped_column(String(36), index=True)
    subject: Mapped[str] = mapped_column(String(255))
    lat: Mapped[float] = mapped_column(Float)
    lon: Mapped[float] = mapped_column(Float)
    speed_kmh: Mapped[float | None] = mapped_column(Float)
    heading: Mapped[float | None] = mapped_column(Float)
    destination: Mapped[str | None] = mapped_column(String(200))
    remaining_km: Mapped[float | None] = mapped_column(Float)
    eta: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    driving: Mapped[bool] = mapped_column(default=True)
    """``False`` – kierowca zakończył nawigację (pozycja zostaje jako ostatnia znana)."""
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class PositionIn(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)
    speed_kmh: float | None = Field(default=None, ge=0, le=250)
    heading: float | None = Field(default=None, ge=0, lt=360)
    destination: str | None = Field(default=None, max_length=200)
    remaining_km: float | None = Field(default=None, ge=0)
    eta: datetime | None = None
    driving: bool = True


class LiveVehicle(BaseModel):
    vehicle_id: str
    name: str
    plate: str | None
    driver: str | None = None
    lat: float | None = None
    lon: float | None = None
    speed_kmh: float | None = None
    heading: float | None = None
    destination: str | None = None
    remaining_km: float | None = None
    eta: datetime | None = None
    at: datetime | None = None
    state: str = "no_signal"
    """``driving`` – jedzie z nawigacją, ``stopped`` – zakończył jazdę, ``no_signal`` – brak
    pozycji albo ostatnia starsza niż ``STALE_AFTER``."""


def live_vehicles(
    db: Session, company_id: str, moment: datetime | None = None
) -> list[LiveVehicle]:
    now = moment or _now()
    vehicles = db.scalars(
        select(VehicleProfile)
        .where(
            VehicleProfile.company_id == company_id,
            VehicleProfile.kind.not_in(("semitrailer", "trailer")),
        )
        .order_by(VehicleProfile.name)
    )
    positions = {
        p.vehicle_id: p
        for p in db.scalars(select(VehiclePosition).where(VehiclePosition.company_id == company_id))
    }
    names = {
        m.subject: m.display_name
        for m in db.scalars(select(CompanyMember).where(CompanyMember.company_id == company_id))
    }
    out = []
    for vehicle in vehicles:
        item = LiveVehicle(vehicle_id=vehicle.id, name=vehicle.name, plate=vehicle.plate)
        if (p := positions.get(vehicle.id)) is not None:
            at = _aware(p.at)
            fresh = now - at <= STALE_AFTER
            item = item.model_copy(
                update={
                    "driver": names.get(p.subject),
                    "lat": p.lat,
                    "lon": p.lon,
                    "speed_kmh": p.speed_kmh if fresh and p.driving else None,
                    "heading": p.heading,
                    "destination": p.destination if p.driving else None,
                    "remaining_km": p.remaining_km if fresh and p.driving else None,
                    "eta": p.eta if fresh and p.driving else None,
                    "at": at,
                    "state": "stopped" if not p.driving else "driving" if fresh else "no_signal",
                }
            )
        out.append(item)
    return out


def build_router(current_user) -> APIRouter:
    router = APIRouter(tags=["live"])
    User = Annotated[Principal, Depends(current_user)]
    Db = Annotated[Session, Depends(get_session)]

    @router.post("/api/vehicles/{vehicle_id}/position", status_code=status.HTTP_204_NO_CONTENT)
    def report_position(vehicle_id: str, data: PositionIn, user: User, db: Db) -> Response:
        """Pozycja z aplikacji kierowcy – tylko pojazd firmy, której kierowca jest członkiem."""
        vehicle = db.get(VehicleProfile, vehicle_id)
        if vehicle is None or vehicle.company_id is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("error.vehicle_not_found"))
        if membership(db, vehicle.company_id, user) is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("error.vehicle_not_found"))
        position = db.get(VehiclePosition, vehicle_id) or VehiclePosition(vehicle_id=vehicle_id)
        position.company_id = vehicle.company_id
        position.subject = user.subject
        for field, value in data.model_dump().items():
            setattr(position, field, value)
        position.at = _now()
        db.add(position)
        db.commit()
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @router.get("/api/companies/{company_id}/live")
    def company_live(company_id: str, user: User, db: Db) -> list[LiveVehicle]:
        require_member(db, company_id, user, VIEWERS)
        return live_vehicles(db, company_id)

    return router
