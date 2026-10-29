"""Profile pojazdów: wymiary i masy, według których liczona jest trasa.

Pojazd jest prywatny (widzi go tylko właściciel) albo należy do firmy – wtedy widzą
go wszyscy jej członkowie, a zmieniają właściciel firmy i dyspozytorzy.
"""

import uuid
from datetime import UTC, datetime
from enum import StrEnum
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Response, status
from pydantic import BaseModel, ConfigDict, Field, model_validator
from sqlalchemy import DateTime, ForeignKey, String, or_, select
from sqlalchemy.orm import Mapped, Session, mapped_column

from truckmaps.core.companies import MANAGES_VEHICLES, company_ids
from truckmaps.core.costs import CostRates
from truckmaps.core.db import Base, get_session
from truckmaps.sdk import Principal

# Znaki i zakazy "dla samochodów ciężarowych" dotyczą pojazdów o DMC powyżej 3,5 t.
HGV_MIN_GVW_T = 3.5


class TrailerType(StrEnum):
    NONE = "none"
    CURTAIN = "curtain"
    BOX = "box"
    REEFER = "reefer"
    TANKER = "tanker"
    FLATBED = "flatbed"
    CONTAINER = "container"
    LOWLOADER = "lowloader"


def _now() -> datetime:
    return datetime.now(UTC)


class VehicleProfile(Base):
    __tablename__ = "vehicle_profiles"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    owner_subject: Mapped[str] = mapped_column(String(255), index=True)
    """Kto dodał pojazd; przy usunięciu firmy pojazd wraca do niego."""
    company_id: Mapped[str | None] = mapped_column(
        ForeignKey("companies.id", ondelete="SET NULL"), index=True
    )
    name: Mapped[str] = mapped_column(String(100))
    height_m: Mapped[float]
    width_m: Mapped[float]
    length_m: Mapped[float]
    weight_t: Mapped[float]
    gvw_t: Mapped[float]
    axle_load_t: Mapped[float]
    axle_count: Mapped[int]
    trailer_type: Mapped[str] = mapped_column(String(20))
    hazmat: Mapped[bool] = mapped_column(default=False)
    cost_eur_per_km: Mapped[float | None]
    cost_eur_per_hour: Mapped[float | None]
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now, onupdate=_now
    )


class VehicleIn(BaseModel):
    """Parametry pojazdu. Zakresy obejmują zestawy nienormatywne, ale odrzucają oczywiste błędy."""

    name: str = Field(min_length=1, max_length=100, examples=["Zestaw 40 t"])
    height_m: float = Field(ge=1.5, le=6.0, description="Wysokość całkowita [m]", examples=[4.0])
    width_m: float = Field(ge=1.5, le=4.5, description="Szerokość [m]", examples=[2.55])
    length_m: float = Field(ge=3.0, le=40.0, description="Długość całkowita [m]", examples=[16.5])
    weight_t: float = Field(ge=1.0, le=150.0, description="Masa rzeczywista [t]", examples=[40])
    gvw_t: float | None = Field(
        default=None,
        ge=1.0,
        le=150.0,
        description="Dopuszczalna masa całkowita – DMC [t]; brak = równa masie rzeczywistej",
        examples=[40],
    )
    axle_load_t: float = Field(
        ge=1.0, le=20.0, description="Największy nacisk osi [t]", examples=[11.5]
    )
    axle_count: int = Field(ge=2, le=20, examples=[5])
    trailer_type: TrailerType = TrailerType.CURTAIN
    hazmat: bool = Field(default=False, description="Przewóz towarów niebezpiecznych (ADR)")

    @model_validator(mode="after")
    def gvw_not_below_weight(self) -> "VehicleIn":
        if self.gvw_t is None:
            self.gvw_t = self.weight_t
        elif self.weight_t > self.gvw_t:
            raise ValueError("Masa rzeczywista nie może być większa niż DMC.")
        return self

    @property
    def is_hgv(self) -> bool:
        """Samochód ciężarowy w rozumieniu znaków i OSM (hgv): DMC powyżej 3,5 t."""
        return (self.gvw_t or self.weight_t) > HGV_MIN_GVW_T


class VehicleData(VehicleIn, CostRates):
    company_id: str | None = Field(
        default=None, description="Firma, do której należy pojazd; brak = pojazd prywatny"
    )


class VehicleOut(VehicleData):
    model_config = ConfigDict(from_attributes=True)

    id: str
    can_edit: bool = True
    """Czy zalogowany użytkownik może zmienić lub usunąć pojazd."""


def build_router(current_user) -> APIRouter:
    router = APIRouter(prefix="/api/vehicles", tags=["vehicles"])
    User = Annotated[Principal, Depends(current_user)]
    Db = Annotated[Session, Depends(get_session)]

    @router.get("")
    def list_vehicles(user: User, db: Db) -> list[VehicleOut]:
        roles = company_ids(db, user)
        query = select(VehicleProfile).where(
            or_(
                (VehicleProfile.owner_subject == user.subject)
                & VehicleProfile.company_id.is_(None),
                VehicleProfile.company_id.in_(roles),
            )
        )
        return [
            vehicle_out(v, roles, user) for v in db.scalars(query.order_by(VehicleProfile.name))
        ]

    @router.post("", status_code=status.HTTP_201_CREATED)
    def create_vehicle(data: VehicleData, user: User, db: Db) -> VehicleOut:
        roles = company_ids(db, user)
        _check_target(data.company_id, roles)
        vehicle = VehicleProfile(owner_subject=user.subject, **data.model_dump())
        db.add(vehicle)
        db.commit()
        return vehicle_out(vehicle, roles, user)

    @router.get("/{vehicle_id}")
    def get_vehicle(vehicle_id: str, user: User, db: Db) -> VehicleOut:
        return vehicle_out(load_owned(db, vehicle_id, user), company_ids(db, user), user)

    @router.put("/{vehicle_id}")
    def update_vehicle(vehicle_id: str, data: VehicleData, user: User, db: Db) -> VehicleOut:
        roles = company_ids(db, user)
        vehicle = load_owned(db, vehicle_id, user, edit=True)
        _check_target(data.company_id, roles)
        for field, value in data.model_dump().items():
            setattr(vehicle, field, value)
        db.commit()
        return vehicle_out(vehicle, roles, user)

    @router.delete("/{vehicle_id}", status_code=status.HTTP_204_NO_CONTENT)
    def delete_vehicle(vehicle_id: str, user: User, db: Db) -> Response:
        db.delete(load_owned(db, vehicle_id, user, edit=True))
        db.commit()
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    return router


def _can_edit(vehicle: VehicleProfile, roles: dict, user: Principal) -> bool:
    if vehicle.company_id is None:
        return vehicle.owner_subject == user.subject
    return roles.get(vehicle.company_id) in MANAGES_VEHICLES


def _check_target(company_id: str | None, roles: dict) -> None:
    """Pojazd można zapisać w firmie tylko jako jej właściciel albo dyspozytor."""
    if company_id is None:
        return
    if company_id not in roles:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Nie znaleziono firmy.")
    if roles[company_id] not in MANAGES_VEHICLES:
        raise HTTPException(
            status.HTTP_403_FORBIDDEN, "Pojazdy firmy dodają właściciel i dyspozytorzy."
        )


def vehicle_out(vehicle: VehicleProfile, roles: dict, user: Principal) -> VehicleOut:
    out = VehicleOut.model_validate(vehicle)
    return out.model_copy(update={"can_edit": _can_edit(vehicle, roles, user)})


def load_owned(
    db: Session, vehicle_id: str, user: Principal, *, edit: bool = False
) -> VehicleProfile:
    """Pojazd prywatny użytkownika albo pojazd jego firmy; obcy wygląda jak nieistniejący (404).

    ``edit=True`` wymaga prawa do zmiany: kierowca firmy jeździ jej pojazdami, ale ich nie zmienia.
    """
    vehicle = db.get(VehicleProfile, vehicle_id)
    roles = company_ids(db, user)
    visible = vehicle is not None and (
        vehicle.company_id in roles
        or (vehicle.company_id is None and vehicle.owner_subject == user.subject)
    )
    if not visible:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Nie znaleziono pojazdu.")
    if edit and not _can_edit(vehicle, roles, user):
        raise HTTPException(
            status.HTTP_403_FORBIDDEN, "Pojazdy firmy zmieniają właściciel i dyspozytorzy."
        )
    return vehicle
