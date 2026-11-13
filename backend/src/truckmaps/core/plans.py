"""Plany kont i ich limity (cennik ze strony: website/assets/js/pricing.js).

Plan ma konto prywatne (kierowca) albo firma. Konto lub firma bez przypisanego planu działa
jak dotąd – bez limitów planu (beta, okres próbny); plan przypisuje rejestracja ze strony
albo administrator. Limity pilnuje serwer: pojazdy z napędem, naczepy / przyczepy, kierowcy,
konta biurowe i trasy w miesiącu. Dodatki („+1 pojazd” itd.) podnoszą limit planu.

Płatny plan bez pierwszej wpłaty w terminie (10 dni od założenia konta) działa jak darmowy
Kierowca Start (konto prywatne) albo bez miejsc ponad to, co już jest (firma) – do czasu
wpłaty albo usunięcia konta (``overdue``).
"""

import uuid
from dataclasses import dataclass, replace
from datetime import UTC, datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import JSON, DateTime, String, select
from sqlalchemy.orm import Mapped, Session, mapped_column

from truckmaps.core.db import Base, get_session
from truckmaps.core.i18n import t
from truckmaps.sdk import Principal

PAYMENT_DAYS = 10
"""Na pierwszą wpłatę za płatny plan – potem konto jest usuwane (zob. regulamin na stronie)."""

TRAILER_KINDS = frozenset({"semitrailer", "trailer"})
"""Naczepy i przyczepy liczone osobno od pojazdów z napędem."""


@dataclass(frozen=True)
class Limits:
    """``None`` – bez limitu."""

    vehicles: int | None = None
    trailers: int | None = None
    drivers: int | None = None
    office: int | None = None
    routes: int | None = None
    """Trasy wyznaczone w miesiącu kalendarzowym (przeliczenia w trakcie jazdy się nie liczą)."""


PLANS: dict[str, Limits] = {
    # Kierowca – konto prywatne. Naczepę dodaje się do pojazdu bez dopłaty.
    "driver.start": Limits(vehicles=1, routes=30),
    "driver.startplus": Limits(vehicles=1),
    "driver.plus": Limits(vehicles=2),
    "driver.pro": Limits(vehicles=3),
    # Przedsiębiorca – tyle samo miejsc na naczepy co na pojazdy.
    "owner.small": Limits(office=2, drivers=5, vehicles=5, trailers=5),
    "owner.fleet": Limits(office=3, drivers=10, vehicles=10, trailers=10),
    "owner.pro": Limits(office=5, drivers=25, vehicles=25, trailers=25),
    "owner.business": Limits(office=10, drivers=60, vehicles=60, trailers=60),
    # Spedytor – pojazdy przewoźników (zestaw = 1); własnej floty nie ma.
    "forwarder.solo": Limits(office=1, vehicles=3),
    "forwarder.start": Limits(office=2, vehicles=5),
    "forwarder.standard": Limits(office=4, vehicles=15),
    "forwarder.pro": Limits(office=8, vehicles=50),
    # Dyspozytor – stanowiska to konta biurowe; naczepy nie wliczają się do limitu.
    "dispatcher.start": Limits(office=1, vehicles=10),
    "dispatcher.standard": Limits(office=1, vehicles=25),
    "dispatcher.pro": Limits(office=2, vehicles=60),
    "dispatcher.center": Limits(office=5, vehicles=150),
}
FREE_PLAN = "driver.start"
PERSONAL_PLANS = frozenset(p for p in PLANS if p.startswith("driver."))

ADDONS: dict[str, str] = {
    "driver": "drivers",
    "vehicle": "vehicles",
    "dvehicle": "vehicles",
    "carrier": "vehicles",
    "trailer": "trailers",
    "office": "office",
    "seat": "office",
}
"""Dodatek ze strony → limit, który podnosi (o liczbę sztuk)."""

BILLINGS = ("monthly", "semiannual", "annual")


def _id() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(UTC)


def _aware(moment: datetime) -> datetime:
    return moment if moment.tzinfo else moment.replace(tzinfo=UTC)


class AccountPlan(Base):
    """Plan konta prywatnego (``subject``) albo firmy (``company_id``)."""

    __tablename__ = "account_plans"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_id)
    subject: Mapped[str | None] = mapped_column(String(255), unique=True)
    company_id: Mapped[str | None] = mapped_column(String(36), unique=True)
    plan: Mapped[str] = mapped_column(String(40))
    billing: Mapped[str | None] = mapped_column(String(20))
    addons: Mapped[dict] = mapped_column(JSON, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    payment_due: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    """Termin pierwszej wpłaty; ``None`` – plan darmowy albo już opłacony."""
    paid_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class RouteUsage(Base):
    """Liczba tras wyznaczonych przez konto w miesiącu (do limitu planu)."""

    __tablename__ = "route_usage"

    subject: Mapped[str] = mapped_column(String(255), primary_key=True)
    month: Mapped[str] = mapped_column(String(7), primary_key=True)
    count: Mapped[int] = mapped_column(default=0)


def is_overdue(plan: AccountPlan, moment: datetime | None = None) -> bool:
    """Płatny plan bez pierwszej wpłaty po terminie."""
    if plan.payment_due is None or plan.paid_until is not None:
        return False
    return _aware(plan.payment_due) <= (moment or _now())


def limits_of(plan: AccountPlan | None) -> Limits | None:
    """Limity planu z dodatkami; ``None`` – brak planu (bez limitów)."""
    if plan is None:
        return None
    if is_overdue(plan):
        # Nieopłacony: konto prywatne – jak darmowy Start, firma – bez nowych miejsc.
        return (
            PLANS[FREE_PLAN]
            if plan.subject
            else Limits(vehicles=0, trailers=0, drivers=0, office=0)
        )
    limits = PLANS.get(plan.plan)
    if limits is None:
        return None
    for addon, count in (plan.addons or {}).items():
        field = ADDONS.get(addon)
        current = getattr(limits, field) if field else None
        if current is not None and isinstance(count, int) and count > 0:
            limits = replace(limits, **{field: current + count})
    return limits


def user_plan(db: Session, subject: str) -> AccountPlan | None:
    return db.scalar(select(AccountPlan).where(AccountPlan.subject == subject))


def company_plan(db: Session, company_id: str) -> AccountPlan | None:
    return db.scalar(select(AccountPlan).where(AccountPlan.company_id == company_id))


def _plan_name(plan: AccountPlan) -> str:
    return t(f"plan.{plan.plan}")


def _limit_error(plan: AccountPlan, key: str, limit: int) -> HTTPException:
    message = t("plan.overdue") if is_overdue(plan) else t(key, plan=_plan_name(plan), limit=limit)
    return HTTPException(status.HTTP_402_PAYMENT_REQUIRED, message)


def check_vehicle(
    db: Session, plan: AccountPlan | None, kind: str, powered: int, trailers: int
) -> None:
    """Czy można dodać pojazd rodzaju ``kind`` przy ``powered`` pojazdach i ``trailers``
    naczepach już zapisanych (konto prywatne albo firma)."""
    limits = limits_of(plan)
    if limits is None:
        return
    if kind in TRAILER_KINDS:
        if limits.trailers is not None and trailers >= limits.trailers:
            raise _limit_error(plan, "plan.limit_trailers", limits.trailers)
        return
    if limits.vehicles is not None and powered >= limits.vehicles:
        raise _limit_error(plan, "plan.limit_vehicles", limits.vehicles)


def check_member(db: Session, company_id: str, role: str, counts: dict[str, int]) -> None:
    """Czy w firmie jest miejsce dla kolejnej osoby w roli ``role`` (``counts``: rola → liczba,
    bez tej osoby)."""
    plan = company_plan(db, company_id)
    limits = limits_of(plan)
    if limits is None:
        return
    if role == "driver":
        if limits.drivers is not None and counts.get("driver", 0) >= limits.drivers:
            raise _limit_error(plan, "plan.limit_drivers", limits.drivers)
        return
    office = sum(n for r, n in counts.items() if r != "driver")
    if limits.office is not None and office >= limits.office:
        raise _limit_error(plan, "plan.limit_office", limits.office)


def _month(moment: datetime | None = None) -> str:
    return (moment or _now()).strftime("%Y-%m")


def routes_used(db: Session, subject: str, moment: datetime | None = None) -> int:
    usage = db.get(RouteUsage, (subject, _month(moment)))
    return usage.count if usage else 0


def count_route(db: Session, subject: str, moment: datetime | None = None) -> None:
    """Nowa trasa konta: limit tras w miesiącu (plan prywatny). Przekroczenie – 402."""
    plan = user_plan(db, subject)
    limits = limits_of(plan)
    if limits is None or limits.routes is None:
        return
    month = _month(moment)
    usage = db.get(RouteUsage, (subject, month))
    if usage is None:
        usage = RouteUsage(subject=subject, month=month, count=0)
        db.add(usage)
    if usage.count >= limits.routes:
        db.rollback()
        raise _limit_error(plan, "plan.limit_routes", limits.routes)
    usage.count += 1
    db.commit()


def assign(
    db: Session,
    plan_id: str,
    *,
    subject: str | None = None,
    company_id: str | None = None,
    billing: str | None = None,
    addons: dict[str, int] | None = None,
    paid: bool = False,
    moment: datetime | None = None,
) -> AccountPlan:
    """Przypisuje plan kontu albo firmie (zastępuje poprzedni). Płatny i nieopłacony –
    z terminem pierwszej wpłaty za ``PAYMENT_DAYS`` dni."""
    if plan_id not in PLANS:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, t("plan.unknown"))
    if (subject is None) == (company_id is None):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, t("plan.owner_required"))
    if (plan_id in PERSONAL_PLANS) != (subject is not None):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, t("plan.wrong_owner"))
    now = moment or _now()
    current = user_plan(db, subject) if subject else company_plan(db, company_id)
    record = current or AccountPlan(subject=subject, company_id=company_id, created_at=now)
    record.plan = plan_id
    record.billing = billing if plan_id != FREE_PLAN else None
    record.addons = {k: int(v) for k, v in (addons or {}).items() if k in ADDONS and int(v) > 0}
    free = plan_id == FREE_PLAN
    if free or paid:
        record.payment_due = None
    elif current is None or (current.payment_due is None and current.paid_until is None):
        record.payment_due = now + timedelta(days=PAYMENT_DAYS)
    if paid:
        months = {"monthly": 1, "semiannual": 6, "annual": 12}.get(billing or "monthly", 1)
        record.paid_until = now + timedelta(days=30 * months)
    db.add(record)
    db.commit()
    return record


def overdue(db: Session, moment: datetime | None = None) -> list[AccountPlan]:
    """Plany bez pierwszej wpłaty po terminie – konta do usunięcia (program administracyjny)."""
    now = moment or _now()
    query = select(AccountPlan).where(
        AccountPlan.payment_due.is_not(None),
        AccountPlan.paid_until.is_(None),
        AccountPlan.payment_due <= now,
    )
    return list(db.scalars(query))


class PlanOut(BaseModel):
    plan: str | None
    name: str | None
    billing: str | None = None
    addons: dict[str, int] = {}
    limits: dict[str, int | None] = {}
    routes_used: int = 0
    payment_due: datetime | None = None
    paid_until: datetime | None = None
    overdue: bool = False


def plan_out(db: Session, plan: AccountPlan | None, subject: str | None = None) -> PlanOut:
    if plan is None:
        return PlanOut(plan=None, name=None)
    limits = limits_of(plan) or Limits()
    return PlanOut(
        plan=plan.plan,
        name=_plan_name(plan),
        billing=plan.billing,
        addons=plan.addons or {},
        limits={k: getattr(limits, k) for k in Limits.__dataclass_fields__},
        routes_used=routes_used(db, subject) if subject else 0,
        payment_due=plan.payment_due,
        paid_until=plan.paid_until,
        overdue=is_overdue(plan),
    )


class PlanIn(BaseModel):
    plan: str
    subject: str | None = None
    company_id: str | None = None
    billing: str | None = Field(default=None, pattern="^(monthly|semiannual|annual)$")
    addons: dict[str, int] = {}
    paid: bool = False


def build_router(current_user, require_admin) -> APIRouter:
    """``/api/me/plan`` – plan zalogowanego; ``/api/admin/plans`` – przypisanie planu
    (administrator, do czasu rejestracji z płatnościami)."""
    router = APIRouter(tags=["plans"])
    User = Annotated[Principal, Depends(current_user)]
    Db = Annotated[Session, Depends(get_session)]

    @router.get("/api/me/plan")
    def my_plan(user: User, db: Db) -> PlanOut:
        return plan_out(db, user_plan(db, user.subject), user.subject)

    @router.get("/api/companies/{company_id}/plan")
    def company_plan_out(company_id: str, user: User, db: Db) -> PlanOut:
        from truckmaps.core.companies import membership  # unikamy cyklu importów

        if membership(db, company_id, user) is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("error.company_not_found"))
        return plan_out(db, company_plan(db, company_id))

    @router.put("/api/admin/plans", dependencies=[Depends(require_admin)])
    def set_plan(data: PlanIn, db: Db) -> PlanOut:
        record = assign(
            db,
            data.plan,
            subject=data.subject,
            company_id=data.company_id,
            billing=data.billing,
            addons=data.addons,
            paid=data.paid,
        )
        return plan_out(db, record, record.subject)

    @router.get("/api/admin/plans/overdue", dependencies=[Depends(require_admin)])
    def list_overdue(db: Db) -> list[PlanOut]:
        return [plan_out(db, p, p.subject) for p in overdue(db)]

    return router
