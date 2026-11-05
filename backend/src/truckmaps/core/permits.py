"""Zezwolenia na przejazd przez ograniczenia (np. wjazd powyżej 3,5 t do miasta, przejazd
nienormatywny po drogach krajowych).

Zezwolenie zapisuje się przy pojeździe albo w firmie dla kilku pojazdów (brak pojazdów –
wszystkie pojazdy firmy / właściciela). Mówi, czego dotyczy (do jakiej masy, nacisku osi,
długości, szerokości, wysokości ze znaku, zakaz dla ciężarówek) i gdzie obowiązuje: cały
kraj, okrąg wokół miejsca (np. miejscowość albo klient) albo wybrane drogi OSM.

W ocenie trasy ograniczenie objęte zezwoleniem – droga w zasięgu, pojazd w limitach
zezwolenia, wyjazd w okresie ważności – nie jest czerwone ani omijane, tylko opisane
„objęte zezwoleniem nr …”. Zmierzony prześwit (wiadukt) nie podlega zezwoleniu – fizycznie
pojazd się nie zmieści. Po wygaśnięciu zezwolenia ograniczenie znów jest omijane.
"""

import uuid
from dataclasses import dataclass
from datetime import UTC, date, datetime
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, ConfigDict, Field, model_validator
from sqlalchemy import JSON, Date, DateTime, Float, String, or_, select
from sqlalchemy.orm import Mapped, Session, mapped_column

from truckmaps.core.companies import MANAGES_VEHICLES, company_ids
from truckmaps.core.db import Base, get_session
from truckmaps.core.i18n import t
from truckmaps.core.restrictions import Kind, distance_m
from truckmaps.sdk import Principal

Scope = Literal["country", "circle", "ways"]


def _now() -> datetime:
    return datetime.now(UTC)


class VehiclePermit(Base):
    __tablename__ = "vehicle_permits"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    company_id: Mapped[str | None] = mapped_column(String(36), index=True)
    owner_subject: Mapped[str] = mapped_column(String(255), index=True)
    vehicle_ids: Mapped[list] = mapped_column(JSON, default=list)
    number: Mapped[str] = mapped_column(String(100))
    issuer: Mapped[str] = mapped_column(String(200), default="")
    valid_from: Mapped[date] = mapped_column(Date)
    valid_to: Mapped[date] = mapped_column(Date)
    max_weight_t: Mapped[float | None] = mapped_column(Float)
    max_axle_t: Mapped[float | None] = mapped_column(Float)
    max_length_m: Mapped[float | None] = mapped_column(Float)
    max_width_m: Mapped[float | None] = mapped_column(Float)
    max_height_m: Mapped[float | None] = mapped_column(Float)
    hgv_ban: Mapped[bool] = mapped_column(default=False)
    scope: Mapped[str] = mapped_column(String(10))
    country: Mapped[str | None] = mapped_column(String(2))
    place: Mapped[str | None] = mapped_column(String(200))
    lat: Mapped[float | None] = mapped_column(Float)
    lon: Mapped[float | None] = mapped_column(Float)
    radius_km: Mapped[float | None] = mapped_column(Float)
    way_ids: Mapped[list] = mapped_column(JSON, default=list)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class PermitIn(BaseModel):
    company_id: str | None = Field(default=None, description="Zezwolenie firmy; brak – prywatne")
    vehicle_ids: list[str] = Field(default=[], max_length=200, description="Brak – wszystkie")
    number: str = Field(min_length=1, max_length=100)
    issuer: str = Field(default="", max_length=200)
    valid_from: date
    valid_to: date
    max_weight_t: float | None = Field(default=None, gt=0, le=250, description="Masa / DMC do")
    max_axle_t: float | None = Field(default=None, gt=0, le=40, description="Nacisk osi do")
    max_length_m: float | None = Field(default=None, gt=0, le=60)
    max_width_m: float | None = Field(default=None, gt=0, le=8)
    max_height_m: float | None = Field(default=None, gt=0, le=6, description="Wysokość ze znaku do")
    hgv_ban: bool = Field(default=False, description="Wjazd mimo zakazu dla ciężarówek")
    scope: Scope = "country"
    country: str | None = Field(default=None, pattern="^[A-Z]{2}$")
    place: str | None = Field(default=None, max_length=200, description="Nazwa miejsca (okrąg)")
    lat: float | None = Field(default=None, ge=-90, le=90)
    lon: float | None = Field(default=None, ge=-180, le=180)
    radius_km: float | None = Field(default=None, gt=0, le=100)
    way_ids: list[int] = Field(default=[], max_length=500, description="Drogi OSM (zasięg ways)")

    @model_validator(mode="after")
    def _complete(self) -> "PermitIn":
        self.number = self.number.strip()
        if self.valid_to < self.valid_from:
            raise ValueError(t("error.permit_dates"))
        limits = (self.max_weight_t, self.max_axle_t, self.max_length_m, self.max_width_m,
                  self.max_height_m)  # fmt: skip
        if not self.hgv_ban and all(v is None for v in limits):
            raise ValueError(t("error.permit_nothing"))
        if self.scope == "country" and not self.country:
            raise ValueError(t("error.permit_country"))
        if self.scope == "circle" and None in (self.lat, self.lon, self.radius_km):
            raise ValueError(t("error.permit_circle"))
        if self.scope == "ways" and not self.way_ids:
            raise ValueError(t("error.permit_ways"))
        return self


class PermitOut(PermitIn):
    model_config = ConfigDict(from_attributes=True)

    id: str
    can_edit: bool = True


@dataclass(frozen=True)
class ActivePermit:
    """Zezwolenie gotowe do oceny trasy (ważne w dniu wyjazdu, dla tego pojazdu)."""

    id: str
    number: str
    max_weight_t: float | None
    max_axle_t: float | None
    max_length_m: float | None
    max_width_m: float | None
    max_height_m: float | None
    hgv_ban: bool
    scope: str
    country: str | None
    lat: float | None
    lon: float | None
    radius_km: float | None
    way_ids: frozenset[int]

    def reaches(self, way_id: int, country: str, point: tuple[float, float]) -> bool:
        if self.scope == "country":
            return country == self.country
        if self.scope == "ways":
            return way_id in self.way_ids
        lon, lat = point
        return distance_m(lon, lat, self.lon, self.lat) <= (self.radius_km or 0) * 1000

    def allows(self, kind: str, vehicle, measured: bool) -> bool:
        """Czy zezwolenie obejmuje ograniczenie tego rodzaju dla pojazdu."""
        if kind == Kind.HGV_NO:
            return self.hgv_ban
        if measured:
            return False  # zmierzony prześwit – fizycznie się nie zmieści
        limit, actual = {
            Kind.WEIGHT: (self.max_weight_t, vehicle.weight_t),
            Kind.WEIGHT_RATING: (self.max_weight_t, vehicle.gvw_t),
            Kind.AXLE_LOAD: (self.max_axle_t, vehicle.axle_load_t),
            Kind.LENGTH: (self.max_length_m, vehicle.length_m),
            Kind.WIDTH: (self.max_width_m, vehicle.width_m),
            Kind.HEIGHT: (self.max_height_m, vehicle.height_m),
        }.get(Kind(kind), (None, None))
        return limit is not None and actual is not None and actual <= limit + 1e-9


def _visible(db: Session, user: Principal):
    roles = company_ids(db, user)
    return roles, select(VehiclePermit).where(
        or_(
            (VehiclePermit.owner_subject == user.subject) & VehiclePermit.company_id.is_(None),
            VehiclePermit.company_id.in_(roles),
        )
    )


def _can_edit(permit: VehiclePermit, roles: dict, user: Principal) -> bool:
    if permit.company_id is None:
        return permit.owner_subject == user.subject
    return roles.get(permit.company_id) in MANAGES_VEHICLES


def active(
    db: Session,
    user: Principal,
    vehicle_ids: set[str],
    day: date,
    chosen: list[str] | None = None,
) -> list[ActivePermit]:
    """Zezwolenia dla pojazdu (i podpiętej naczepy) ważne w dniu ``day``; ``chosen`` – tylko
    zaznaczone w planerze (brak – wszystkie ważne)."""
    _, query = _visible(db, user)
    found = []
    for p in db.scalars(
        query.where(VehiclePermit.valid_from <= day, VehiclePermit.valid_to >= day)
    ):
        if chosen is not None and p.id not in chosen:
            continue
        if p.vehicle_ids and not set(p.vehicle_ids) & vehicle_ids:
            continue
        found.append(
            ActivePermit(
                id=p.id, number=p.number, max_weight_t=p.max_weight_t, max_axle_t=p.max_axle_t,
                max_length_m=p.max_length_m, max_width_m=p.max_width_m,
                max_height_m=p.max_height_m, hgv_ban=p.hgv_ban, scope=p.scope,
                country=p.country, lat=p.lat, lon=p.lon, radius_km=p.radius_km,
                way_ids=frozenset(p.way_ids or []),
            )
        )  # fmt: skip
    return found


def build_router(current_user) -> APIRouter:
    router = APIRouter(prefix="/api/permits", tags=["permits"])
    User = Annotated[Principal, Depends(current_user)]
    Db = Annotated[Session, Depends(get_session)]

    def out(permit: VehiclePermit, roles: dict, user: Principal) -> PermitOut:
        return PermitOut.model_validate(permit).model_copy(
            update={"can_edit": _can_edit(permit, roles, user)}
        )

    def check(data: PermitIn, roles: dict) -> None:
        if data.company_id is not None and roles.get(data.company_id) not in MANAGES_VEHICLES:
            raise HTTPException(status.HTTP_403_FORBIDDEN, t("error.permit_forbidden"))

    def load(db: Session, permit_id: str, user: Principal) -> tuple[VehiclePermit, dict]:
        roles, query = _visible(db, user)
        permit = db.scalar(query.where(VehiclePermit.id == permit_id))
        if permit is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("error.permit_not_found"))
        if not _can_edit(permit, roles, user):
            raise HTTPException(status.HTTP_403_FORBIDDEN, t("error.permit_forbidden"))
        return permit, roles

    @router.get("")
    def list_permits(
        user: User, db: Db, vehicle_id: str | None = None, day: date | None = None
    ) -> list[PermitOut]:
        """Zezwolenia widoczne dla użytkownika; z ``vehicle_id`` i ``day`` – tylko pasujące."""
        roles, query = _visible(db, user)
        if day is not None:
            query = query.where(VehiclePermit.valid_from <= day, VehiclePermit.valid_to >= day)
        permits = [
            p
            for p in db.scalars(query.order_by(VehiclePermit.valid_to.desc()))
            if vehicle_id is None or not p.vehicle_ids or vehicle_id in p.vehicle_ids
        ]
        return [out(p, roles, user) for p in permits]

    @router.post("", status_code=status.HTTP_201_CREATED)
    def create_permit(data: PermitIn, user: User, db: Db) -> PermitOut:
        roles = company_ids(db, user)
        check(data, roles)
        permit = VehiclePermit(owner_subject=user.subject, **data.model_dump())
        db.add(permit)
        db.commit()
        return out(permit, roles, user)

    @router.put("/{permit_id}")
    def update_permit(permit_id: str, data: PermitIn, user: User, db: Db) -> PermitOut:
        permit, roles = load(db, permit_id, user)
        check(data, roles)
        for field, value in data.model_dump().items():
            setattr(permit, field, value)
        db.commit()
        return out(permit, roles, user)

    @router.delete("/{permit_id}", status_code=status.HTTP_204_NO_CONTENT)
    def delete_permit(permit_id: str, user: User, db: Db) -> None:
        permit, _ = load(db, permit_id, user)
        db.delete(permit)
        db.commit()

    return router
