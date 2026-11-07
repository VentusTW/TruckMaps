"""Pojazdy dla modułów (``truckmaps.sdk.fleet.Fleet``) – widoczność jak w ``/api/vehicles``."""

from collections.abc import Callable, Iterator
from datetime import date, datetime

from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from truckmaps.core import inbox, shared
from truckmaps.core.companies import SERVICES_VEHICLES, Company, CompanyMember, company_ids
from truckmaps.core.db import get_session
from truckmaps.core.trips import VehicleTrip
from truckmaps.core.vehicles import VehicleProfile, load_owned
from truckmaps.sdk import Principal
from truckmaps.sdk.fleet import (
    PRIVATE,
    TANK_BODIES,
    CargoInfo,
    CompanyInfo,
    DriverAssignedHandler,
    DrivingInfo,
    MemberInfo,
    TripInfo,
    VehicleInfo,
)

PeriodicJob = tuple[str, Callable[[Session], int]]


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


MergeHandler = Callable[[Session, str, str], None]


def service_staff(db: Session, vehicle: VehicleProfile) -> list[str]:
    """Właściciel, dyspozytorzy i mechanicy firmy pojazdu; pojazd prywatny – jego właściciel."""
    if vehicle.company_id is None:
        return [vehicle.owner_subject]
    return list(
        db.scalars(
            select(CompanyMember.subject).where(
                CompanyMember.company_id == vehicle.company_id,
                CompanyMember.role.in_(SERVICES_VEHICLES),
            )
        )
    )


class CoreFleet:
    def __init__(
        self,
        merge_handlers: list[MergeHandler] | None = None,
        driver_handlers: list[DriverAssignedHandler] | None = None,
    ) -> None:
        # Wspólne listy całej aplikacji – program administratora wywołuje je przy scalaniu,
        # ``PUT /api/vehicles/{id}/driver`` przy zmianie przydziału kierowcy.
        self._merge_handlers = merge_handlers if merge_handlers is not None else []
        self._driver_handlers = driver_handlers if driver_handlers is not None else []

    def on_driver_assigned(self, handler: DriverAssignedHandler) -> None:
        self._driver_handlers.append(handler)

    def members(self, db: Session, company_id: str) -> list[MemberInfo]:
        query = select(CompanyMember).where(CompanyMember.company_id == company_id)
        return [
            MemberInfo(id=m.id, subject=m.subject, name=m.display_name, role=m.role)
            for m in db.scalars(query.order_by(CompanyMember.display_name))
        ]

    def company(self, db: Session, company_id: str) -> CompanyInfo | None:
        company = db.get(Company, company_id)
        if company is None:
            return None
        return CompanyInfo(
            id=company.id, name=company.name, tax_id=company.tax_id, kind=str(company.kind)
        )

    def driving(self, db: Session, vehicle_id: str) -> DrivingInfo | None:
        vehicle = db.get(VehicleProfile, vehicle_id)
        if vehicle is None:
            return None
        trailer = db.get(VehicleProfile, vehicle.trailer_id) if vehicle.trailer_id else None
        return DrivingInfo(
            vehicle_id=vehicle.id,
            name=vehicle.name,
            plate=vehicle.plate,
            kind=vehicle.kind,
            company_id=vehicle.company_id,
            gvw_t=vehicle.gvw_t or vehicle.weight_t,
            seats=vehicle.seats,
            hazmat=bool(vehicle.hazmat or (trailer and trailer.hazmat)),
            tanker=vehicle.trailer_type in TANK_BODIES
            or bool(trailer and trailer.trailer_type in TANK_BODIES),
            trailer_kind=trailer.kind if trailer else None,
            trailer_gvw_t=(trailer.gvw_t or trailer.weight_t) if trailer else None,
            assigned_driver=vehicle.assigned_driver,
            trailer_plate=trailer.plate if trailer else None,
            odometer_km=vehicle.odometer_km,
        )

    def assigned(self, db: Session, company_id: str) -> dict[str, str]:
        query = select(VehicleProfile.id, VehicleProfile.assigned_driver).where(
            VehicleProfile.company_id == company_id, VehicleProfile.assigned_driver.is_not(None)
        )
        return {vehicle_id: subject for vehicle_id, subject in db.execute(query)}

    def assign_driver(
        self, db: Session, vehicle_id: str, subject: str | None, name: str | None = None
    ) -> None:
        vehicle = db.get(VehicleProfile, vehicle_id)
        if vehicle is not None:
            vehicle.assigned_driver = subject
            vehicle.assigned_driver_label = name

    def trips(
        self,
        db: Session,
        *,
        driver: str | None = None,
        vehicle_ids: list[str] | None = None,
        since: datetime | None = None,
    ) -> list[TripInfo]:
        if driver is None and not vehicle_ids:
            return []
        query = select(VehicleTrip, VehicleProfile.name).join(
            VehicleProfile, VehicleProfile.id == VehicleTrip.vehicle_id
        )
        if driver is not None:
            query = query.where(VehicleTrip.driver == driver)
        if vehicle_ids:
            query = query.where(VehicleTrip.vehicle_id.in_(vehicle_ids))
        if since is not None:
            query = query.where(VehicleTrip.started_at >= since)
        rows = db.execute(query.order_by(VehicleTrip.started_at.desc()))
        return [
            TripInfo(
                id=trip.id, vehicle_id=trip.vehicle_id, vehicle_name=name, driver=trip.driver,
                started_at=trip.started_at, ended_at=trip.ended_at,
                distance_km=trip.distance_km, planned_km=trip.planned_km, loaded=trip.loaded,
                idle_min=trip.idle_min, trailer_id=trip.trailer_id,
                cost_amount=trip.cost_amount, cost_currency=trip.cost_currency,
            )
            for trip, name in rows
        ]  # fmt: skip

    def on_vehicles_merged(self, handler: MergeHandler) -> None:
        self._merge_handlers.append(handler)

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

    def set_repair_reported(self, db: Session, vehicle_id: str, reported: bool) -> None:
        vehicle = db.get(VehicleProfile, vehicle_id)
        if vehicle is not None:
            vehicle.repair_reported = reported

    def record_inspection(self, db: Session, vehicle_id: str, day: date, valid_until: date) -> None:
        vehicle = db.get(VehicleProfile, vehicle_id)
        if vehicle is not None:
            vehicle.last_inspection = day
            vehicle.inspection_until = valid_until

    def cargo(self, db: Session, vehicle_id: str) -> CargoInfo:
        vehicle = db.get(VehicleProfile, vehicle_id)
        if vehicle is None:
            return CargoInfo(deck_length_m=None, payload_kg=None)
        deck = round(vehicle.pallet_places / 33 * 13.6, 2) if vehicle.pallet_places else None
        gvw = vehicle.gvw_t or vehicle.weight_t
        payload = (gvw - vehicle.tare_t) * 1000 if vehicle.tare_t is not None else None
        return CargoInfo(
            deck_length_m=deck,
            payload_kg=payload,
            kind=vehicle.kind,
            axle_count=vehicle.axle_count,
            axle_load_t=vehicle.axle_load_t,
            tare_kg=vehicle.tare_t * 1000 if vehicle.tare_t is not None else None,
            gvw_kg=gvw * 1000,
            height_m=vehicle.height_m,
            kingpin_m=vehicle.kingpin_m,
            axles_m=vehicle.axles_m,
            wheelbase_m=vehicle.wheelbase_m,
            body="" if vehicle.trailer_type == "none" else vehicle.trailer_type,
        )

    def staff(self, db: Session, vehicle_id: str) -> list[str]:
        vehicle = db.get(VehicleProfile, vehicle_id)
        return [] if vehicle is None else service_staff(db, vehicle)

    def notify(
        self, db: Session, recipients: list[str], kind: str, data: dict, company_id: str | None
    ) -> None:
        inbox.send(db, recipients, kind, sender_name="", company_id=company_id, data=data)


class CoreStorage:
    def __init__(self, jobs: list[PeriodicJob] | None = None) -> None:
        self._jobs = jobs if jobs is not None else []

    def periodic(self, name: str, job: Callable[[Session], int]) -> None:
        self._jobs.append((name, job))

    @property
    def session(self) -> Callable[..., Iterator[Session]]:
        return get_session

    def share(
        self, db: Session, body: bytes, content_type: str, filename: str, minutes: int = 15
    ) -> str:
        return shared.share(db, body, content_type, filename, minutes)
