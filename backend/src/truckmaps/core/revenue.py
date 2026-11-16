"""Przychody ze zleceń transportowych – stawka przy trasie od dyspozytora.

Zlecenie transportowe to trasa wysłana kierowcy (``RouteAssignment``). Przychód trzymamy we
wspólnych wpisach (``EntityRecord``: ``entity_type="order"``, ``entity_id`` = id trasy,
``kind="order_revenue"``) – bez osobnej tabeli. Kwota może wynikać ze stawki za km
(stawka × długość trasy). Podsumowanie przelicza waluty po kursach EBC (``currency``) na walutę
docelową; kwoty bez kursu zostają tylko w rozbiciu na waluty.

Przychody widzą i wpisują właściciel i dyspozytor (``dispatch.PLANNERS``).
"""

from datetime import UTC, datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from pydantic import BaseModel, Field, model_validator
from sqlalchemy import select
from sqlalchemy.orm import Session

from truckmaps.core.companies import require_member
from truckmaps.core.currency import latest_rates
from truckmaps.core.db import get_session
from truckmaps.core.dispatch import PLANNERS, RouteAssignment
from truckmaps.core.i18n import t
from truckmaps.core.records import EntityRecord
from truckmaps.core.vehicles import VehicleProfile
from truckmaps.sdk import Principal

KIND = "order_revenue"
ENTITY = "order"


class RevenueIn(BaseModel):
    amount: float | None = Field(default=None, ge=0, description="Kwota zlecenia")
    currency: str = Field(default="PLN", pattern="^[A-Za-z]{3}$")
    rate_per_km: float | None = Field(
        default=None, ge=0, description="Stawka za km – gdy brak kwoty, kwota = stawka × km trasy"
    )

    @model_validator(mode="after")
    def _something(self) -> "RevenueIn":
        if self.amount is None and self.rate_per_km is None:
            raise ValueError("amount or rate_per_km required")
        return self


class OrderRevenue(BaseModel):
    assignment_id: str
    vehicle_id: str
    plate: str | None
    label: str
    """Skąd → dokąd."""
    distance_km: float | None
    state: str
    created_at: datetime
    amount: float | None
    """Kwota w walucie zlecenia; ``None`` – przychodu nie wpisano."""
    currency: str | None
    rate_per_km: float | None


class MonthRevenue(BaseModel):
    month: str
    """``RRRR-MM``."""
    total: float


class VehicleRevenue(BaseModel):
    vehicle_id: str
    plate: str | None
    count: int
    km: float
    total: float


class SummaryOut(BaseModel):
    since: datetime
    currency: str
    """Waluta, na którą przeliczono ``total``."""
    count: int
    """Zlecenia z wpisanym przychodem."""
    orders_total: int
    amount: dict[str, float]
    """Waluta → suma kwot przed przeliczeniem."""
    total: float
    """Suma przeliczona na ``currency`` (bez kwot, dla których brak kursu)."""
    unconverted: list[str]
    """Waluty bez kursu – ich kwot nie ma w ``total``."""
    km: float
    """Długość tras zleceń z przychodem."""
    per_km: float | None
    months: list[MonthRevenue]
    vehicles: list[VehicleRevenue]
    orders: list[OrderRevenue]


def _record(db: Session, company_id: str, assignment_id: str) -> EntityRecord | None:
    return db.scalar(
        select(EntityRecord).where(
            EntityRecord.company_id == company_id,
            EntityRecord.entity_type == ENTITY,
            EntityRecord.entity_id == assignment_id,
            EntityRecord.kind == KIND,
        )
    )


def _label(a: RouteAssignment) -> str:
    stops = a.stops or []
    if not stops:
        return ""
    return f"{stops[0].get('label', '')} → {stops[-1].get('label', '')}"


def _order(a: RouteAssignment, plate: str | None, record: EntityRecord | None) -> OrderRevenue:
    data = record.data if record else {}
    return OrderRevenue(
        assignment_id=a.id,
        vehicle_id=a.vehicle_id,
        plate=plate,
        label=_label(a),
        distance_km=a.distance_km,
        state=a.state,
        created_at=a.created_at,
        amount=data.get("amount"),
        currency=data.get("currency"),
        rate_per_km=data.get("rate_per_km"),
    )


def build_router(current_user) -> APIRouter:
    router = APIRouter(tags=["revenue"])
    User = Annotated[Principal, Depends(current_user)]
    Db = Annotated[Session, Depends(get_session)]

    def assignment(db: Session, company_id: str, assignment_id: str) -> RouteAssignment:
        a = db.get(RouteAssignment, assignment_id)
        if a is None or a.company_id != company_id:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("dispatch.not_found"))
        return a

    def plate(db: Session, vehicle_id: str) -> str | None:
        vehicle = db.get(VehicleProfile, vehicle_id)
        return vehicle.plate if vehicle else None

    @router.put("/api/companies/{company_id}/route-assignments/{assignment_id}/revenue")
    def set_revenue(
        company_id: str, assignment_id: str, data: RevenueIn, user: User, db: Db
    ) -> OrderRevenue:
        """Wpisuje albo zmienia przychód zlecenia (kwota albo stawka za km)."""
        require_member(db, company_id, user, PLANNERS)
        a = assignment(db, company_id, assignment_id)
        amount = data.amount
        if amount is None:
            if not a.distance_km:
                raise HTTPException(
                    status.HTTP_422_UNPROCESSABLE_CONTENT, t("revenue.distance_unknown")
                )
            amount = data.rate_per_km * a.distance_km
        value = {
            "amount": round(amount, 2),
            "currency": data.currency.upper(),
            "rate_per_km": data.rate_per_km,
            "vehicle_id": a.vehicle_id,
        }
        record = _record(db, company_id, a.id)
        now = datetime.now(UTC)
        if record is None:
            record = EntityRecord(
                company_id=company_id, entity_type=ENTITY, entity_id=a.id, kind=KIND,
                data=value, created_by=user.subject,
            )  # fmt: skip
            db.add(record)
        else:
            record.data = value
            record.updated_at = now
        db.commit()
        return _order(a, plate(db, a.vehicle_id), record)

    @router.delete(
        "/api/companies/{company_id}/route-assignments/{assignment_id}/revenue", status_code=204
    )
    def delete_revenue(company_id: str, assignment_id: str, user: User, db: Db) -> Response:
        require_member(db, company_id, user, PLANNERS)
        a = assignment(db, company_id, assignment_id)
        record = _record(db, company_id, a.id)
        if record is not None:
            db.delete(record)
            db.commit()
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @router.get("/api/companies/{company_id}/revenue/summary")
    def summary(
        company_id: str,
        user: User,
        db: Db,
        months: Annotated[int, Query(ge=1, le=36)] = 6,
        currency: Annotated[str, Query(pattern="^[A-Za-z]{3}$")] = "PLN",
    ) -> SummaryOut:
        """Zlecenia z ostatnich ``months`` miesięcy i ich przychody (razem, miesiące, pojazdy)."""
        require_member(db, company_id, user, PLANNERS)
        target = currency.upper()
        since = datetime.now(UTC) - timedelta(days=30 * months)
        assignments = db.scalars(
            select(RouteAssignment)
            .where(RouteAssignment.company_id == company_id, RouteAssignment.created_at >= since)
            .order_by(RouteAssignment.created_at.desc())
        ).all()
        records = {
            r.entity_id: r
            for r in db.scalars(
                select(EntityRecord).where(
                    EntityRecord.company_id == company_id,
                    EntityRecord.entity_type == ENTITY,
                    EntityRecord.kind == KIND,
                )
            )
        }
        plates = {
            v.id: v.plate
            for v in db.scalars(
                select(VehicleProfile).where(VehicleProfile.company_id == company_id)
            )
        }
        rates = latest_rates(db)
        amounts: dict[str, float] = {}
        missing: set[str] = set()
        per_month: dict[str, float] = {}
        per_vehicle: dict[str, VehicleRevenue] = {}
        total = km = per_km_total = 0.0
        count = 0
        orders = []
        for a in assignments:
            order = _order(a, plates.get(a.vehicle_id), records.get(a.id))
            orders.append(order)
            if order.amount is None:
                continue
            count += 1
            source = order.currency or "PLN"
            amounts[source] = round(amounts.get(source, 0) + order.amount, 2)
            value = rates.convert(order.amount, source, target)
            if value is None:
                missing.add(source)
                continue
            distance = a.distance_km or 0
            total += value
            if distance:
                km += distance
                per_km_total += value
            month = a.created_at.strftime("%Y-%m")
            per_month[month] = per_month.get(month, 0) + value
            group = per_vehicle.setdefault(
                a.vehicle_id,
                VehicleRevenue(vehicle_id=a.vehicle_id, plate=order.plate, count=0, km=0, total=0),
            )
            group.count += 1
            group.km = round(group.km + distance, 1)
            group.total = round(group.total + value, 2)
        return SummaryOut(
            since=since,
            currency=target,
            count=count,
            orders_total=len(orders),
            amount=amounts,
            total=round(total, 2),
            unconverted=sorted(missing),
            km=round(km, 1),
            per_km=round(per_km_total / km, 2) if km else None,
            months=[MonthRevenue(month=m, total=round(v, 2)) for m, v in sorted(per_month.items())],
            vehicles=sorted(per_vehicle.values(), key=lambda g: -g.total),
            orders=orders,
        )

    return router
