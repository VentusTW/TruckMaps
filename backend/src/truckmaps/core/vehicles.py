"""Profile pojazdów użytkownika: wymiary i masy, według których liczona jest trasa."""

import uuid
from datetime import UTC, datetime
from enum import StrEnum
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Response, status
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import DateTime, String, select
from sqlalchemy.orm import Mapped, Session, mapped_column

from truckmaps.core.db import Base, get_session
from truckmaps.sdk import Principal


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
    name: Mapped[str] = mapped_column(String(100))
    height_m: Mapped[float]
    width_m: Mapped[float]
    length_m: Mapped[float]
    weight_t: Mapped[float]
    axle_load_t: Mapped[float]
    axle_count: Mapped[int]
    trailer_type: Mapped[str] = mapped_column(String(20))
    hazmat: Mapped[bool] = mapped_column(default=False)
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
    weight_t: float = Field(ge=3.5, le=150.0, description="Masa rzeczywista [t]", examples=[40])
    axle_load_t: float = Field(
        ge=1.0, le=20.0, description="Największy nacisk osi [t]", examples=[11.5]
    )
    axle_count: int = Field(ge=2, le=20, examples=[5])
    trailer_type: TrailerType = TrailerType.CURTAIN
    hazmat: bool = Field(default=False, description="Przewóz towarów niebezpiecznych (ADR)")


class VehicleOut(VehicleIn):
    model_config = ConfigDict(from_attributes=True)

    id: str


def build_router(current_user) -> APIRouter:
    router = APIRouter(prefix="/api/vehicles", tags=["vehicles"])
    User = Annotated[Principal, Depends(current_user)]
    Db = Annotated[Session, Depends(get_session)]

    @router.get("")
    def list_vehicles(user: User, db: Db) -> list[VehicleOut]:
        query = select(VehicleProfile).where(VehicleProfile.owner_subject == user.subject)
        return [
            VehicleOut.model_validate(v) for v in db.scalars(query.order_by(VehicleProfile.name))
        ]

    @router.post("", status_code=status.HTTP_201_CREATED)
    def create_vehicle(data: VehicleIn, user: User, db: Db) -> VehicleOut:
        vehicle = VehicleProfile(owner_subject=user.subject, **data.model_dump())
        db.add(vehicle)
        db.commit()
        return VehicleOut.model_validate(vehicle)

    @router.get("/{vehicle_id}")
    def get_vehicle(vehicle_id: str, user: User, db: Db) -> VehicleOut:
        return VehicleOut.model_validate(load_owned(db, vehicle_id, user))

    @router.put("/{vehicle_id}")
    def update_vehicle(vehicle_id: str, data: VehicleIn, user: User, db: Db) -> VehicleOut:
        vehicle = load_owned(db, vehicle_id, user)
        for field, value in data.model_dump().items():
            setattr(vehicle, field, value)
        db.commit()
        return VehicleOut.model_validate(vehicle)

    @router.delete("/{vehicle_id}", status_code=status.HTTP_204_NO_CONTENT)
    def delete_vehicle(vehicle_id: str, user: User, db: Db) -> Response:
        db.delete(load_owned(db, vehicle_id, user))
        db.commit()
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    return router


def load_owned(db: Session, vehicle_id: str, user: Principal) -> VehicleProfile:
    """Pojazd użytkownika; cudzy pojazd wygląda jak nieistniejący (404)."""
    vehicle = db.get(VehicleProfile, vehicle_id)
    if vehicle is None or vehicle.owner_subject != user.subject:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Nie znaleziono pojazdu.")
    return vehicle
