"""Serwis pojazdów: kierowca albo dyspozytor zgłasza usterkę, mechanik przyjmuje zlecenie,
naprawia i zamyka je protokołem (czynności, części, czas pracy, przebieg).

Pojazd jest „w naprawie” (niedostępny do jazdy), gdy naprawa trwa albo zgłoszono, że stoi.
Moduł korzysta tylko z SDK rdzenia: pojazdy widzi przez ``ctx.fleet``, bazę przez ``ctx.storage``.
"""

import json
import uuid
from datetime import UTC, datetime
from enum import StrEnum
from importlib import resources
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import JSON, DateTime, String, Text, select
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column

from truckmaps.sdk import SERVICE_ROLES, CoreContext, Module, Principal, VehicleInfo, i18n
from truckmaps.sdk.i18n import t


class Base(DeclarativeBase):
    """Tabele modułu – osobno od rdzenia, z własną gałęzią migracji (``service``)."""


class Status(StrEnum):
    NEW = "new"
    ACCEPTED = "accepted"
    IN_PROGRESS = "in_progress"
    DONE = "done"
    REJECTED = "rejected"


OPEN = {Status.NEW, Status.ACCEPTED, Status.IN_PROGRESS}

Urgency = Literal["can_drive", "stopped"]
"""Czy pojazd może jechać do naprawy, czy stoi."""


def _now() -> datetime:
    return datetime.now(UTC)


class ServiceOrder(Base):
    __tablename__ = "service_orders"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    vehicle_id: Mapped[str] = mapped_column(String(36), index=True)
    company_id: Mapped[str | None] = mapped_column(String(36), index=True)
    reported_by: Mapped[str] = mapped_column(String(255))
    reporter_name: Mapped[str] = mapped_column(String(200), default="")
    description: Mapped[str] = mapped_column(Text)
    urgency: Mapped[str] = mapped_column(String(10), default="can_drive")
    status: Mapped[str] = mapped_column(String(12), default=Status.NEW)
    mechanic: Mapped[str | None] = mapped_column(String(255))
    mechanic_name: Mapped[str | None] = mapped_column(String(200))
    work_done: Mapped[str | None] = mapped_column(Text)
    parts: Mapped[list] = mapped_column(JSON, default=list)
    labour_hours: Mapped[float | None]
    odometer_km: Mapped[int | None]
    notes: Mapped[str | None] = mapped_column(Text)
    reject_reason: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class Part(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    quantity: float = Field(default=1, gt=0, le=10_000)
    price: float | None = Field(default=None, ge=0, le=10_000_000, description="Cena jednostkowa")


class ReportIn(BaseModel):
    vehicle_id: str
    description: str = Field(min_length=3, max_length=2000, examples=["Wycieka olej spod silnika"])
    urgency: Urgency = "can_drive"


class ProtocolIn(BaseModel):
    """Protokół naprawy zamykający zlecenie."""

    work_done: str = Field(min_length=3, max_length=4000)
    parts: list[Part] = Field(default_factory=list, max_length=100)
    labour_hours: float | None = Field(default=None, ge=0, le=1000)
    odometer_km: int | None = Field(default=None, ge=0, le=10_000_000)
    notes: str = Field(default="", max_length=2000)


class RejectIn(BaseModel):
    reason: str = Field(min_length=3, max_length=1000)


class OrderOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    vehicle_id: str
    vehicle_name: str = ""
    vehicle_plate: str | None = None
    company_id: str | None
    reporter_name: str
    description: str
    urgency: str
    status: Status
    mechanic_name: str | None
    work_done: str | None
    parts: list[Part]
    labour_hours: float | None
    odometer_km: int | None
    notes: str | None
    reject_reason: str | None
    created_at: datetime
    updated_at: datetime
    completed_at: datetime | None
    can_handle: bool = False
    """Czy zalogowany może przyjąć, prowadzić i zamknąć zlecenie (mechanik, dyspozytor…)."""


def _name(user: Principal) -> str:
    claims = user.claims
    return str(claims.get("name") or claims.get("email") or user.subject[-6:])[:200]


class ServiceModule(Module):
    id = "service"
    name = "Serwis"
    version = "0.1.0"
    requires_core = ">=0.1,<1.0"

    def register(self, ctx: CoreContext) -> None:
        for file in (resources.files("truckmaps_service") / "locales").iterdir():
            if file.name.endswith(".json"):
                i18n.register(file.name.removesuffix(".json"), json.loads(file.read_text("utf-8")))

        router = APIRouter()
        User = Annotated[Principal, Depends(ctx.auth.current_user)]
        Db = Annotated[Session, Depends(ctx.storage.session)]
        fleet = ctx.fleet

        def out(order: ServiceOrder, vehicle: VehicleInfo | None) -> OrderOut:
            result = OrderOut.model_validate(order)
            if vehicle is None:
                return result
            return result.model_copy(
                update={
                    "vehicle_name": vehicle.name,
                    "vehicle_plate": vehicle.plate,
                    "can_handle": vehicle.role in SERVICE_ROLES,
                }
            )

        def load(db: Session, user: Principal, order_id: str) -> tuple[ServiceOrder, VehicleInfo]:
            order = db.get(ServiceOrder, order_id)
            vehicle = order and fleet.vehicle(db, user, order.vehicle_id)
            if order is None or vehicle is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, t("service.order_not_found"))
            return order, vehicle

        def handle(db: Session, user: Principal, order_id: str, allowed: set[Status]):
            order, vehicle = load(db, user, order_id)
            if vehicle.role not in SERVICE_ROLES:
                raise HTTPException(status.HTTP_403_FORBIDDEN, t("service.handle_forbidden"))
            if order.status not in allowed:
                raise HTTPException(status.HTTP_409_CONFLICT, t("service.wrong_status"))
            return order, vehicle

        def refresh_repair(db: Session, vehicle_id: str) -> None:
            """W naprawie: naprawa trwa albo zgłoszono, że pojazd stoi (do zamknięcia zlecenia)."""
            orders = db.scalars(
                select(ServiceOrder).where(
                    ServiceOrder.vehicle_id == vehicle_id, ServiceOrder.status.in_(list(OPEN))
                )
            )
            in_repair = any(
                o.status == Status.IN_PROGRESS or o.urgency == "stopped" for o in orders
            )
            fleet.set_in_repair(db, vehicle_id, in_repair)

        def save(db: Session, order: ServiceOrder, vehicle: VehicleInfo) -> OrderOut:
            order.updated_at = _now()
            db.flush()
            refresh_repair(db, order.vehicle_id)
            db.commit()
            return out(order, vehicle)

        @router.get("/orders")
        def list_orders(
            user: User,
            db: Db,
            vehicle_id: str | None = None,
            open_only: bool = False,
        ) -> list[OrderOut]:
            """Zlecenia dla pojazdów widocznych dla użytkownika, od najnowszych."""
            vehicles = {v.id: v for v in fleet.vehicles(db, user)}
            ids = [vehicle_id] if vehicle_id in vehicles else list(vehicles)
            query = select(ServiceOrder).where(ServiceOrder.vehicle_id.in_(ids))
            if open_only:
                query = query.where(ServiceOrder.status.in_(list(OPEN)))
            orders = db.scalars(query.order_by(ServiceOrder.created_at.desc()))
            return [out(o, vehicles[o.vehicle_id]) for o in orders]

        @router.post("/orders", status_code=status.HTTP_201_CREATED)
        def report(data: ReportIn, user: User, db: Db) -> OrderOut:
            """Zgłoszenie usterki – każdy, kto widzi pojazd (także kierowca)."""
            vehicle = fleet.vehicle(db, user, data.vehicle_id)
            if vehicle is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, t("service.vehicle_not_found"))
            order = ServiceOrder(
                vehicle_id=vehicle.id,
                company_id=vehicle.company_id,
                reported_by=user.subject,
                reporter_name=_name(user),
                description=data.description.strip(),
                urgency=data.urgency,
                parts=[],
            )
            db.add(order)
            return save(db, order, vehicle)

        @router.post("/orders/{order_id}/accept")
        def accept(order_id: str, user: User, db: Db) -> OrderOut:
            order, vehicle = handle(db, user, order_id, {Status.NEW})
            order.status = Status.ACCEPTED
            order.mechanic, order.mechanic_name = user.subject, _name(user)
            return save(db, order, vehicle)

        @router.post("/orders/{order_id}/start")
        def start(order_id: str, user: User, db: Db) -> OrderOut:
            order, vehicle = handle(db, user, order_id, {Status.NEW, Status.ACCEPTED})
            order.status = Status.IN_PROGRESS
            if order.mechanic is None:
                order.mechanic, order.mechanic_name = user.subject, _name(user)
            return save(db, order, vehicle)

        @router.post("/orders/{order_id}/complete")
        def complete(order_id: str, data: ProtocolIn, user: User, db: Db) -> OrderOut:
            """Zamknięcie protokołem naprawy."""
            order, vehicle = handle(db, user, order_id, OPEN)
            order.status = Status.DONE
            order.work_done = data.work_done.strip()
            order.parts = [p.model_dump() for p in data.parts]
            order.labour_hours = data.labour_hours
            order.odometer_km = data.odometer_km
            order.notes = data.notes.strip() or None
            order.completed_at = _now()
            if order.mechanic is None:
                order.mechanic, order.mechanic_name = user.subject, _name(user)
            return save(db, order, vehicle)

        @router.post("/orders/{order_id}/reject")
        def reject(order_id: str, data: RejectIn, user: User, db: Db) -> OrderOut:
            order, vehicle = handle(db, user, order_id, {Status.NEW, Status.ACCEPTED})
            order.status = Status.REJECTED
            order.reject_reason = data.reason.strip()
            return save(db, order, vehicle)

        ctx.api.include_router(router)
