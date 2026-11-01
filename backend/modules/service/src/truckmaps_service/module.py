"""Serwis pojazdów: kierowca albo dyspozytor zgłasza usterkę, mechanik przyjmuje zlecenie,
naprawia i zamyka je protokołem (czynności, części, czas pracy, przebieg).

Pojazd jest „w naprawie” (niedostępny do jazdy), gdy naprawa trwa albo zgłoszono, że stoi.
Do zgłoszenia i protokołu można dołączyć zdjęcia; o nowym zgłoszeniu dowiaduje się obsługa
pojazdu, o zakończonej naprawie – zgłaszający (skrzynka w aplikacji). Protokół do druku
(HTML – przeglądarka zapisze go jako PDF) i koszty napraw według pojazdów.
Moduł korzysta tylko z SDK rdzenia: pojazdy widzi przez ``ctx.fleet``, bazę przez ``ctx.storage``.
"""

import base64
import binascii
import html
import json
import uuid
from collections import defaultdict
from datetime import UTC, date, datetime
from enum import StrEnum
from importlib import resources
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import JSON, Date, DateTime, LargeBinary, String, Text, func, select, update
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column

from truckmaps.sdk import SERVICE_ROLES, CoreContext, Module, Principal, VehicleInfo, i18n
from truckmaps.sdk.i18n import language, t

MAX_PHOTOS = 10
MAX_PHOTO_BYTES = 2_000_000
"""Zdjęcie po zmniejszeniu w aplikacji (do 1600 px) ma kilkaset kB; większe odrzucamy."""
PHOTO_TYPES = {b"\xff\xd8\xff": "image/jpeg", b"\x89PNG": "image/png"}


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
    inspection_until: Mapped[date | None] = mapped_column(Date)
    """Zrobiony przegląd techniczny – ważny do (przesuwa terminy pojazdu)."""
    currency: Mapped[str | None] = mapped_column(String(3))
    """Waluta cen części w protokole."""
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class ServicePhoto(Base):
    __tablename__ = "service_photos"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    order_id: Mapped[str] = mapped_column(String(36), index=True)
    stage: Mapped[str] = mapped_column(String(10))
    """report – przy zgłoszeniu, protocol – przy naprawie."""
    content_type: Mapped[str] = mapped_column(String(20))
    data: Mapped[bytes] = mapped_column(LargeBinary)
    added_by: Mapped[str] = mapped_column(String(255))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


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
    inspection_until: date | None = Field(
        default=None,
        description="Zrobiony przegląd techniczny – ważny do (przesuwa terminy pojazdu)",
    )
    currency: str | None = Field(
        default=None, pattern="^[A-Z]{3}$", description="Waluta cen części (ISO 4217)"
    )


class PhotoIn(BaseModel):
    image: str = Field(description="Zdjęcie JPEG albo PNG w base64")
    stage: Literal["report", "protocol"] = "report"


class PhotoOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    stage: str
    created_at: datetime


class VehicleCosts(BaseModel):
    """Koszty zakończonych napraw pojazdu w jednej walucie."""

    vehicle_id: str
    vehicle_name: str
    vehicle_plate: str | None
    currency: str | None
    """``None`` – ceny części bez waluty."""
    orders: int
    parts_total: float
    labour_hours: float


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
    inspection_until: date | None = None
    currency: str | None = None
    photos: list[PhotoOut] = []
    created_at: datetime
    updated_at: datetime
    completed_at: datetime | None
    can_handle: bool = False
    """Czy zalogowany może przyjąć, prowadzić i zamknąć zlecenie (mechanik, dyspozytor…)."""


def _parts_total(order: ServiceOrder) -> float:
    return sum((p.get("price") or 0) * p.get("quantity", 1) for p in order.parts or [])


def _photo(data: str) -> tuple[bytes, str]:
    try:
        raw = base64.b64decode(data, validate=True)
    except (binascii.Error, ValueError):
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_CONTENT, t("service.photo_invalid")
        ) from None
    kind = next((k for magic, k in PHOTO_TYPES.items() if raw.startswith(magic)), None)
    if kind is None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, t("service.photo_invalid"))
    if len(raw) > MAX_PHOTO_BYTES:
        raise HTTPException(status.HTTP_413_CONTENT_TOO_LARGE, t("service.photo_too_large"))
    return raw, kind


def _protocol_html(order: ServiceOrder, vehicle: VehicleInfo, photos: list[ServicePhoto]) -> str:
    """Protokół naprawy do druku – przeglądarka zapisze go jako PDF („Drukuj”)."""
    e = html.escape

    def row(label: str, value) -> str:
        if value in (None, ""):
            return ""
        return f"<tr><th>{e(label)}</th><td>{e(str(value))}</td></tr>"

    money = (lambda v: f"{v:.2f} {order.currency}") if order.currency else (lambda v: f"{v:.2f}")
    parts = "".join(
        f"<tr><td>{e(p['name'])}</td><td>{p.get('quantity', 1):g}</td>"
        f"<td>{money(p['price']) if p.get('price') is not None else ''}</td></tr>"
        for p in order.parts or []
    )
    completed = f"{order.completed_at:%Y-%m-%d}" if order.completed_at else ""
    images = "".join(
        f'<img src="data:{p.content_type};base64,{base64.b64encode(p.data).decode()}" alt="">'
        for p in photos
    )
    return f"""<!doctype html><html lang="{language()}"><head><meta charset="utf-8">
<title>{e(t("service.protocol_title"))} – {e(vehicle.name)}</title>
<style>body{{font-family:sans-serif;margin:24px;color:#111}}
table{{border-collapse:collapse;width:100%;margin:12px 0}}
th,td{{border:1px solid #999;padding:6px;text-align:left;vertical-align:top}}
th{{width:30%;background:#eee}}img{{max-width:48%;margin:4px}}
@media print{{button{{display:none}}}}</style></head><body>
<button onclick="window.print()">{e(t("service.protocol_print"))}</button>
<h1>{e(t("service.protocol_title"))}</h1>
<table>
{row(t("service.protocol_vehicle"), " · ".join(x for x in (vehicle.name, vehicle.plate) if x))}
{row(t("service.protocol_reported"), f"{order.created_at:%Y-%m-%d} – {order.reporter_name}")}
{row(t("service.protocol_fault"), order.description)}
{row(t("service.protocol_completed"), completed)}
{row(t("service.protocol_mechanic"), order.mechanic_name)}
{row(t("service.protocol_work"), order.work_done)}
{row(t("service.protocol_hours"), order.labour_hours)}
{row(t("service.protocol_odometer"), order.odometer_km)}
{row(t("service.protocol_inspection"), order.inspection_until)}
{row(t("service.protocol_notes"), order.notes)}
</table>
{f"<h2>{e(t('service.protocol_parts'))}</h2><table>{parts}</table>" if parts else ""}
{row(t("service.protocol_parts_total"), money(_parts_total(order))) if parts else ""}
{images}
<p><br>{e(t("service.protocol_signature"))}: ............................</p>
</body></html>"""


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

        def out(order: ServiceOrder, vehicle: VehicleInfo | None, db: Session) -> OrderOut:
            photos = db.scalars(
                select(ServicePhoto)
                .where(ServicePhoto.order_id == order.id)
                .order_by(ServicePhoto.created_at)
            )
            result = OrderOut.model_validate(order).model_copy(
                update={"photos": [PhotoOut.model_validate(p) for p in photos]}
            )
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
            """W naprawie: naprawa trwa albo zgłoszono, że pojazd stoi (do zamknięcia zlecenia).
            Inne otwarte zlecenie – usterka zgłoszona, pojazd jeszcze jeździ."""
            orders = list(
                db.scalars(
                    select(ServiceOrder).where(
                        ServiceOrder.vehicle_id == vehicle_id, ServiceOrder.status.in_(list(OPEN))
                    )
                )
            )
            in_repair = any(
                o.status == Status.IN_PROGRESS or o.urgency == "stopped" for o in orders
            )
            fleet.set_in_repair(db, vehicle_id, in_repair)
            fleet.set_repair_reported(db, vehicle_id, bool(orders) and not in_repair)

        def vehicles_merged(db: Session, kept_id: str, merged_id: str) -> None:
            """Zlecenia zdublowanego pojazdu przechodzą na zachowany (z historią napraw)."""
            db.execute(
                update(ServiceOrder)
                .where(ServiceOrder.vehicle_id == merged_id)
                .values(vehicle_id=kept_id)
            )
            refresh_repair(db, kept_id)

        def message(order: ServiceOrder, vehicle: VehicleInfo) -> dict:
            return {
                "order_id": order.id,
                "vehicle_id": vehicle.id,
                "vehicle_name": vehicle.name,
                "plate": vehicle.plate,
                "description": order.description[:200],
                "urgency": order.urgency,
            }

        fleet.on_vehicles_merged(vehicles_merged)

        def save(db: Session, order: ServiceOrder, vehicle: VehicleInfo) -> OrderOut:
            order.updated_at = _now()
            db.flush()
            refresh_repair(db, order.vehicle_id)
            db.commit()
            return out(order, vehicle, db)

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
            return [out(o, vehicles[o.vehicle_id], db) for o in orders]

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
            db.flush()
            staff = [s for s in fleet.staff(db, vehicle.id) if s != user.subject]
            data_out = message(order, vehicle) | {"reporter_name": order.reporter_name}
            fleet.notify(db, staff, "service.order_new", data_out, vehicle.company_id)
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
            order.currency = data.currency
            order.completed_at = _now()
            if data.inspection_until is not None:
                if data.inspection_until <= order.completed_at.date():
                    raise HTTPException(
                        status.HTTP_422_UNPROCESSABLE_CONTENT, t("service.inspection_past")
                    )
                order.inspection_until = data.inspection_until
                fleet.record_inspection(
                    db, order.vehicle_id, order.completed_at.date(), data.inspection_until
                )
            if order.mechanic is None:
                order.mechanic, order.mechanic_name = user.subject, _name(user)
            if order.reported_by != user.subject:
                done = message(order, vehicle) | {"mechanic_name": order.mechanic_name}
                fleet.notify(
                    db, [order.reported_by], "service.order_done", done, vehicle.company_id
                )
            return save(db, order, vehicle)

        @router.post("/orders/{order_id}/photos", status_code=status.HTTP_201_CREATED)
        def add_photo(order_id: str, data: PhotoIn, user: User, db: Db) -> OrderOut:
            """Zdjęcie usterki (każdy, kto widzi pojazd) albo naprawy (obsługa pojazdu)."""
            order, vehicle = load(db, user, order_id)
            if data.stage == "protocol" and vehicle.role not in SERVICE_ROLES:
                raise HTTPException(status.HTTP_403_FORBIDDEN, t("service.handle_forbidden"))
            count = db.scalar(select(func.count()).where(ServicePhoto.order_id == order.id))
            if count >= MAX_PHOTOS:
                raise HTTPException(
                    status.HTTP_409_CONFLICT, t("service.photo_limit", count=MAX_PHOTOS)
                )
            raw, kind = _photo(data.image)
            db.add(
                ServicePhoto(
                    order_id=order.id, stage=data.stage, content_type=kind, data=raw,
                    added_by=user.subject,
                )
            )  # fmt: skip
            return save(db, order, vehicle)

        @router.get("/photos/{photo_id}")
        def photo(photo_id: str, user: User, db: Db) -> dict:
            """Zdjęcie w base64 (aplikacja pokazuje je z pamięci)."""
            found = db.get(ServicePhoto, photo_id)
            if found is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, t("service.order_not_found"))
            load(db, user, found.order_id)  # sprawdza, czy użytkownik widzi pojazd
            return {
                "content_type": found.content_type,
                "image": base64.b64encode(found.data).decode(),
            }

        @router.get("/orders/{order_id}/protocol")
        def protocol(order_id: str, user: User, db: Db) -> dict:
            """Protokół naprawy do druku (strona HTML w polu ``html``) – tylko zakończone zlecenie.
            Aplikacja otwiera ją w przeglądarce, która zapisze ją jako PDF."""
            order, vehicle = load(db, user, order_id)
            if order.status != Status.DONE:
                raise HTTPException(status.HTTP_409_CONFLICT, t("service.wrong_status"))
            photos = list(
                db.scalars(
                    select(ServicePhoto)
                    .where(ServicePhoto.order_id == order.id)
                    .order_by(ServicePhoto.created_at)
                )
            )
            name = f"{order.completed_at:%Y-%m-%d}-{vehicle.plate or vehicle.name}"
            return {
                "html": _protocol_html(order, vehicle, photos),
                "filename": "".join(c if c.isalnum() or c in "-_" else "_" for c in name),
            }

        @router.get("/costs")
        def costs(
            user: User, db: Db, date_from: date | None = None, date_to: date | None = None
        ) -> list[VehicleCosts]:
            """Koszty zakończonych napraw według pojazdów (części i godziny pracy), w okresie."""
            vehicles = {v.id: v for v in fleet.vehicles(db, user) if v.role in SERVICE_ROLES}
            query = select(ServiceOrder).where(
                ServiceOrder.vehicle_id.in_(list(vehicles)), ServiceOrder.status == Status.DONE
            )
            totals: dict[tuple[str, str | None], list] = defaultdict(lambda: [0, 0.0, 0.0])
            for order in db.scalars(query):
                day = order.completed_at.date() if order.completed_at else None
                if day is None or (date_from and day < date_from) or (date_to and day > date_to):
                    continue
                total = totals[(order.vehicle_id, order.currency)]
                total[0] += 1
                total[1] += _parts_total(order)
                total[2] += order.labour_hours or 0
            return [
                VehicleCosts(
                    vehicle_id=vehicle_id,
                    vehicle_name=vehicles[vehicle_id].name,
                    vehicle_plate=vehicles[vehicle_id].plate,
                    currency=currency,
                    orders=n,
                    parts_total=round(parts, 2),
                    labour_hours=round(hours, 2),
                )
                for (vehicle_id, currency), (n, parts, hours) in sorted(
                    totals.items(), key=lambda item: vehicles[item[0][0]].name
                )
            ]

        @router.post("/orders/{order_id}/reject")
        def reject(order_id: str, data: RejectIn, user: User, db: Db) -> OrderOut:
            order, vehicle = handle(db, user, order_id, {Status.NEW, Status.ACCEPTED})
            order.status = Status.REJECTED
            order.reject_reason = data.reason.strip()
            return save(db, order, vehicle)

        ctx.api.include_router(router)
