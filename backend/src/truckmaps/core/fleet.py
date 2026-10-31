"""Pojazdy dla modułów (``truckmaps.sdk.fleet.Fleet``) – widoczność jak w ``/api/vehicles``."""

from collections.abc import Callable, Iterator

from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from truckmaps.core.companies import company_ids
from truckmaps.core.db import get_session
from truckmaps.core.vehicles import VehicleProfile, load_owned
from truckmaps.sdk import Principal
from truckmaps.sdk.fleet import PRIVATE, VehicleInfo


def _info(vehicle: VehicleProfile, roles: dict) -> VehicleInfo:
    role = PRIVATE if vehicle.company_id is None else str(roles.get(vehicle.company_id))
    return VehicleInfo(
        id=vehicle.id,
        name=vehicle.name,
        plate=vehicle.plate,
        kind=vehicle.kind,
        company_id=vehicle.company_id,
        role=role,
        in_repair=bool(vehicle.in_repair),
    )


class CoreFleet:
    def vehicles(self, db: Session, user: Principal) -> list[VehicleInfo]:
        roles = company_ids(db, user)
        query = select(VehicleProfile).where(
            or_(
                (VehicleProfile.owner_subject == user.subject)
                & VehicleProfile.company_id.is_(None),
                VehicleProfile.company_id.in_(roles),
            )
        )
        return [_info(v, roles) for v in db.scalars(query.order_by(VehicleProfile.name))]

    def vehicle(self, db: Session, user: Principal, vehicle_id: str) -> VehicleInfo | None:
        try:
            vehicle = load_owned(db, vehicle_id, user)
        except Exception:  # noqa: BLE001 – obcy albo nieistniejący pojazd: dla modułu po prostu brak
            return None
        return _info(vehicle, company_ids(db, user))

    def set_in_repair(self, db: Session, vehicle_id: str, in_repair: bool) -> None:
        vehicle = db.get(VehicleProfile, vehicle_id)
        if vehicle is not None:
            vehicle.in_repair = in_repair


class CoreStorage:
    @property
    def session(self) -> Callable[..., Iterator[Session]]:
        return get_session
