"""Pulpit operacyjny dyspozytora: wskaźniki floty, sprawy wymagające uwagi i aktualizacje na żywo.

Wszystko liczone z danych, które TruckMaps już ma: pojazdy i ich terminy, przejazdy (km, koszty,
odchylenie od planu), skrzynka wiadomości. Moduły dokładają swoje części przez gniazdo zbiorcze
``DASHBOARD_FEED`` (np. terminy kierowców, otwarte zlecenia serwisowe) – tylko te wykupione przez
konto. Bez telematyki: spalanie z CAN, TPMS, chłodnie i punktualność z GPS nie są pokazywane
(``telematics: false``). Teksty składa aplikacja z kluczy (``key`` / ``kind``) – pliki .arb.

Aktualizacje na żywo: Server-Sent Events (``/api/dashboard/stream``) – serwer co kilka sekund
liczy stan i wysyła go tylko po zmianie, a między zmianami – komentarz podtrzymujący połączenie.
"""

import asyncio
import hashlib
import json
import logging
from collections.abc import AsyncIterator, Awaitable, Callable
from datetime import UTC, date, datetime, timedelta
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field
from sqlalchemy import DateTime, String, Text, func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Mapped, Session, mapped_column

from truckmaps.core import inbox, reminders
from truckmaps.core.companies import MANAGES_VEHICLES, Company, CompanyBase, require_member
from truckmaps.core.db import Base, get_session
from truckmaps.core.i18n import t
from truckmaps.core.trips import VehicleTrip
from truckmaps.core.vehicles import TOWED, VehicleProfile, person_names
from truckmaps.sdk import (
    DASHBOARD_FEED,
    DashboardAlert,
    DashboardKpi,
    DashboardPart,
    Principal,
)

log = logging.getLogger(__name__)

STREAM_INTERVAL_S = 15.0
"""Co ile sekund strumień sprawdza zmiany (``app.state.dashboard_interval`` w testach)."""
PLAN_WINDOW_DAYS = 7
"""Odchylenie km od planu – z przejazdów z ostatnich dni."""
SEVERITY_RANK = {"critical": 0, "warning": 1, "info": 2}


def _now() -> datetime:
    return datetime.now(UTC)


def _aware(moment: datetime | None) -> datetime | None:
    # SQLite (testy) zwraca daty bez strefy czasowej.
    return moment if moment is None or moment.tzinfo else moment.replace(tzinfo=UTC)


class AlertAck(Base):
    """Obsłużona sprawa z pulpitu – zarazem dziennik działań dyspozytora (kto, co, kiedy).

    Klucz (firma, sprawa) chroni przed podwójnym kliknięciem: druga akcja na tej samej sprawie
    niczego nie powtarza (np. nie wysyła drugiej wiadomości do kierowcy)."""

    __tablename__ = "dashboard_alert_acks"

    company_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    alert_id: Mapped[str] = mapped_column(String(200), primary_key=True)
    action: Mapped[str] = mapped_column(String(20))
    by_subject: Mapped[str] = mapped_column(String(255))
    by_name: Mapped[str] = mapped_column(String(200), default="")
    note: Mapped[str | None] = mapped_column(Text)
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class Handled(BaseModel):
    action: str
    by_name: str
    at: datetime
    note: str | None = None


class AlertOut(DashboardAlert):
    source: str = "core"
    """Kto zgłosił sprawę: "core" albo id modułu."""
    vehicle_name: str | None = None
    plate: str | None = None
    driver_name: str | None = None
    actions: list[str] = []
    handled: Handled | None = None


class KpiOut(DashboardKpi):
    source: str = "core"


class Overview(BaseModel):
    company_id: str
    company_name: str
    user_name: str
    role: str
    bases: list[str]
    generated_at: datetime
    telematics: bool = False
    """Dane z CAN/TPMS/GPS na żywo – na razie brak integracji; kafle ⚡ ukryte."""
    sources: list[str]
    """Moduły, które dołożyły części pulpitu."""
    kpis: list[KpiOut]
    alert_counts: dict[str, int]


class ActionIn(BaseModel):
    company_id: str
    action: Literal["acknowledge", "message_driver"]
    text: str | None = Field(default=None, max_length=500)


class ActionOut(BaseModel):
    alert_id: str
    action: str
    duplicate: bool
    """Sprawę już obsłużono wcześniej – nic nie powtórzono."""
    handled: Handled


# ---------------------------------------------------------------- liczenie


def _health_tone(percent: float) -> str:
    return "ok" if percent >= 90 else ("warning" if percent >= 75 else "error")


def _due_severity(data: dict, today: date) -> str:
    if data.get("overdue"):
        return "critical"
    if "day" in data:
        return "warning" if (date.fromisoformat(data["day"]) - today).days <= 7 else "info"
    return "warning"


def core_part(db: Session, company_id: str, today: date) -> DashboardPart:
    """Flota, terminy pojazdów i przejazdy firmy."""
    now = _now()
    vehicles = list(
        db.scalars(select(VehicleProfile).where(VehicleProfile.company_id == company_id))
    )
    power = [v for v in vehicles if v.kind not in TOWED]
    in_use = [v for v in power if (until := _aware(v.in_use_until)) is not None and until > now]
    available = [v for v in power if v not in in_use and not v.in_repair and not v.repair_reported]
    service = [v for v in vehicles if v.in_repair or v.repair_reported]

    alerts: list[DashboardAlert] = []
    overdue_vehicles: set[str] = set()
    for v in vehicles:
        driver = v.assigned_driver or (v.in_use_by if v in in_use else None)
        for field, marker, data in reminders.due(v, today):
            if data.get("overdue"):
                overdue_vehicles.add(v.id)
            alerts.append(
                DashboardAlert(
                    id=f"vehicle:due:{v.id}:{field}:{marker}",
                    kind="vehicle_due",
                    severity=_due_severity(data, today),  # type: ignore[arg-type]
                    data={"field": field, **data},
                    vehicle_id=v.id,
                    driver_subject=driver,
                    due=date.fromisoformat(data["day"]) if "day" in data else None,
                )
            )
        if v.repair_reported and not v.in_repair:
            alerts.append(
                DashboardAlert(
                    id=f"vehicle:reported:{v.id}:{_stamp(v.updated_at)}",
                    kind="vehicle_reported",
                    severity="warning",
                    vehicle_id=v.id,
                    driver_subject=driver,
                )
            )
        elif v.in_repair:
            alerts.append(
                DashboardAlert(
                    id=f"vehicle:repair:{v.id}:{_stamp(v.updated_at)}",
                    kind="vehicle_repair",
                    severity="info",
                    vehicle_id=v.id,
                )
            )

    healthy = [v for v in vehicles if v.id not in overdue_vehicles and not v.in_repair]
    health = round(100 * len(healthy) / len(vehicles), 1) if vehicles else 100.0
    deadlines = sum(1 for a in alerts if a.kind == "vehicle_due")
    overdue = sum(1 for a in alerts if a.kind == "vehicle_due" and a.severity == "critical")

    kpis = [
        DashboardKpi(key="fleet.active", value=len(in_use), total=len(power), order=10),
        DashboardKpi(
            key="fleet.available", value=len(available), total=len(power), tone="ok", order=20
        ),
        DashboardKpi(
            key="fleet.service", value=len(service), tone="warning" if service else "ok", order=30
        ),
        DashboardKpi(
            key="fleet.health",
            value=health,
            unit="%",
            tone=_health_tone(health),
            order=40,  # type: ignore[arg-type]
        ),
        DashboardKpi(
            key="fleet.deadlines",
            value=deadlines,
            tone="error" if overdue else ("warning" if deadlines else "ok"),
            order=50,
        ),
    ]
    kpis += _trip_kpis(db, [v.id for v in vehicles], today)
    return DashboardPart(kpis=kpis, alerts=alerts)


def _stamp(moment: datetime | None) -> str:
    moment = _aware(moment)
    return moment.strftime("%Y%m%d%H%M") if moment else "0"


def _trip_kpis(db: Session, vehicle_ids: list[str], today: date) -> list[DashboardKpi]:
    if not vehicle_ids:
        return []
    start = datetime.combine(today, datetime.min.time(), UTC)
    trips = list(
        db.scalars(
            select(VehicleTrip).where(
                VehicleTrip.vehicle_id.in_(vehicle_ids),
                VehicleTrip.ended_at >= start - timedelta(days=PLAN_WINDOW_DAYS - 1),
            )
        )
    )
    today_trips = [tr for tr in trips if _aware(tr.ended_at) >= start]  # type: ignore[operator]
    kpis = [
        DashboardKpi(key="trips.today", value=len(today_trips), order=60),
        DashboardKpi(
            key="trips.km_today",
            value=round(sum(tr.distance_km for tr in today_trips)),
            unit="km",
            order=70,
        ),
    ]
    costs: dict[str, float] = {}
    for tr in today_trips:
        if tr.cost_amount is not None and tr.cost_currency:
            costs[tr.cost_currency] = costs.get(tr.cost_currency, 0) + tr.cost_amount
    for currency, amount in sorted(costs.items()):
        kpis.append(
            DashboardKpi(key="costs.today", value=round(amount, 2), unit=currency, order=80)
        )
    planned = [tr for tr in trips if tr.planned_km]
    if planned:
        plan = sum(tr.planned_km for tr in planned)  # type: ignore[misc]
        driven = sum(tr.distance_km for tr in planned)
        deviation = round(100 * (driven - plan) / plan, 1)
        tone = "ok" if abs(deviation) <= 5 else ("warning" if abs(deviation) <= 15 else "error")
        kpis.append(
            DashboardKpi(key="trips.plan_deviation", value=deviation, unit="%", tone=tone, order=90)  # type: ignore[arg-type]
        )
    return kpis


def collect(
    request: Request, db: Session, company_id: str, user: Principal
) -> list[tuple[DashboardPart, str]]:
    """Części pulpitu: rdzeń + moduły wykupione przez konto (błąd modułu nie psuje pulpitu)."""
    today = date.today()
    parts = [(core_part(db, company_id, today), "core")]
    licensing = request.app.state.licensing
    feeds = request.app.state.extensions.all_allowed(
        DASHBOARD_FEED, lambda m: licensing.is_granted(user, m)
    )
    for feed, owner in feeds:
        try:
            parts.append((feed.collect(db, company_id, today), owner))
        except Exception:  # noqa: BLE001 – część modułu nie może zablokować pulpitu
            log.exception("Część pulpitu modułu %s nie powiodła się", owner)
    return parts


def alerts_of(
    db: Session, company_id: str, parts: list[tuple[DashboardPart, str]], include_handled: bool
) -> list[AlertOut]:
    acks = {
        a.alert_id: a for a in db.scalars(select(AlertAck).where(AlertAck.company_id == company_id))
    }
    raw = [(a, owner) for part, owner in parts for a in part.alerts]
    vehicle_ids = {a.vehicle_id for a, _ in raw if a.vehicle_id}
    vehicles = (
        {
            v.id: v
            for v in db.scalars(select(VehicleProfile).where(VehicleProfile.id.in_(vehicle_ids)))
        }
        if vehicle_ids
        else {}
    )
    names = person_names(db, {a.driver_subject for a, _ in raw if a.driver_subject}, company_id)
    result = []
    for alert, owner in raw:
        ack = acks.get(alert.id)
        if ack is not None and not include_handled:
            continue
        vehicle = vehicles.get(alert.vehicle_id or "")
        out = AlertOut(
            **alert.model_dump(),
            source=owner,
            vehicle_name=vehicle.name if vehicle else None,
            plate=vehicle.plate if vehicle else None,
            driver_name=names.get(alert.driver_subject or ""),
            actions=["acknowledge", *(["message_driver"] if alert.driver_subject else [])],
            handled=_handled(ack) if ack else None,
        )
        result.append(out)
    result.sort(key=lambda a: (SEVERITY_RANK[a.severity], a.due or date.max, a.id))
    return result


def _handled(ack: AlertAck) -> Handled:
    return Handled(action=ack.action, by_name=ack.by_name, at=_aware(ack.at), note=ack.note)  # type: ignore[arg-type]


def overview_of(
    db: Session,
    company_id: str,
    user: Principal,
    parts: list[tuple[DashboardPart, str]],
    alerts: list[AlertOut],
) -> Overview:
    company = db.get(Company, company_id)
    member = require_member(db, company_id, user)
    bases = db.scalars(select(CompanyBase.name).where(CompanyBase.company_id == company_id))
    kpis = [KpiOut(**k.model_dump(), source=owner) for part, owner in parts for k in part.kpis]
    unread = db.scalar(
        select(func.count()).where(
            inbox.Message.recipient == user.subject, inbox.Message.read_at.is_(None)
        )
    )
    kpis.append(KpiOut(key="inbox.unread", value=unread or 0, tone="info", order=200))
    kpis.sort(key=lambda k: (k.order, k.key, k.unit))
    counts = {s: sum(1 for a in alerts if a.severity == s) for s in SEVERITY_RANK}
    return Overview(
        company_id=company_id,
        company_name=company.name if company else "",
        user_name=member.display_name,
        role=member.role,
        bases=list(bases),
        generated_at=_now(),
        sources=sorted({owner for _, owner in parts}),
        kpis=kpis,
        alert_counts=counts,
    )


def snapshot(request: Request, db: Session, company_id: str, user: Principal) -> dict:
    parts = collect(request, db, company_id, user)
    alerts = alerts_of(db, company_id, parts, include_handled=False)
    overview = overview_of(db, company_id, user, parts, alerts)
    return {
        "overview": overview.model_dump(mode="json"),
        "alerts": [a.model_dump(mode="json") for a in alerts],
    }


def fingerprint(state: dict) -> str:
    """Odcisk stanu bez znacznika czasu – zmiana odcisku = jest co wysłać."""
    overview = {k: v for k, v in state["overview"].items() if k != "generated_at"}
    body = json.dumps(
        {"overview": overview, "alerts": state["alerts"]}, sort_keys=True, default=str
    )
    return hashlib.sha256(body.encode()).hexdigest()


async def stream_events(
    compute: Callable[[], Awaitable[dict]],
    interval: float,
    disconnected: Callable[[], Awaitable[bool]],
    once: bool = False,
) -> AsyncIterator[str]:
    """Zdarzenia SSE: ``snapshot`` po każdej zmianie stanu, komentarz ``ping`` między nimi."""
    last = None
    while not await disconnected():
        state = await compute()
        mark = fingerprint(state)
        if mark != last:
            last = mark
            yield f"event: snapshot\ndata: {json.dumps(state, default=str)}\n\n"
        else:
            yield ": ping\n\n"
        if once:
            return
        await asyncio.sleep(interval)


# ---------------------------------------------------------------- API


def build_router(current_user) -> APIRouter:
    router = APIRouter(prefix="/api/dashboard", tags=["dashboard"])
    User = Annotated[Principal, Depends(current_user)]
    Db = Annotated[Session, Depends(get_session)]
    CompanyId = Annotated[str, Query(min_length=1, max_length=36)]

    def check(db: Session, company_id: str, user: Principal) -> None:
        require_member(db, company_id, user, MANAGES_VEHICLES)

    @router.get("/overview")
    def overview(request: Request, company_id: CompanyId, user: User, db: Db) -> Overview:
        check(db, company_id, user)
        parts = collect(request, db, company_id, user)
        alerts = alerts_of(db, company_id, parts, include_handled=False)
        return overview_of(db, company_id, user, parts, alerts)

    @router.get("/alerts")
    def alerts(
        request: Request, company_id: CompanyId, user: User, db: Db, include_handled: bool = False
    ) -> list[AlertOut]:
        check(db, company_id, user)
        return alerts_of(db, company_id, collect(request, db, company_id, user), include_handled)

    @router.post("/alerts/{alert_id}/action")
    def act(alert_id: str, body: ActionIn, request: Request, user: User, db: Db) -> ActionOut:
        member = require_member(db, body.company_id, user, MANAGES_VEHICLES)
        existing = db.get(AlertAck, (body.company_id, alert_id))
        if existing is not None:
            return ActionOut(
                alert_id=alert_id,
                action=existing.action,
                duplicate=True,
                handled=_handled(existing),
            )
        parts = collect(request, db, body.company_id, user)
        alert = next(
            (
                a
                for a in alerts_of(db, body.company_id, parts, include_handled=True)
                if a.id == alert_id
            ),
            None,
        )
        if alert is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("dashboard.alert_not_found"))
        text = (body.text or "").strip()
        if body.action == "message_driver":
            if not alert.driver_subject:
                raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, t("dashboard.no_driver"))
            if not text:
                raise HTTPException(
                    status.HTTP_422_UNPROCESSABLE_CONTENT, t("dashboard.text_required")
                )
        ack = AlertAck(
            company_id=body.company_id,
            alert_id=alert_id,
            action=body.action,
            by_subject=user.subject,
            by_name=member.display_name,
            note=text or None,
        )
        db.add(ack)
        try:
            db.flush()
        except IntegrityError:
            # Drugie kliknięcie w tej samej chwili – pierwsze już zapisało sprawę.
            db.rollback()
            existing = db.get(AlertAck, (body.company_id, alert_id))
            return ActionOut(
                alert_id=alert_id,
                action=existing.action,
                duplicate=True,
                handled=_handled(existing),
            )  # type: ignore[union-attr]
        if body.action == "message_driver":
            inbox.send(
                db,
                [alert.driver_subject],  # type: ignore[list-item]
                inbox.Kind.DISPATCH_NOTE,
                sender_name=member.display_name,
                company_id=body.company_id,
                data={
                    "text": text,
                    "alert_kind": alert.kind,
                    "vehicle_name": alert.vehicle_name,
                    "plate": alert.plate,
                },
            )
        db.commit()
        log.info(
            "Pulpit: %s %s sprawę %s w firmie %s",
            user.subject,
            body.action,
            alert_id,
            body.company_id,
        )
        return ActionOut(
            alert_id=alert_id, action=body.action, duplicate=False, handled=_handled(ack)
        )

    @router.delete("/alerts/{alert_id}/action", status_code=status.HTTP_204_NO_CONTENT)
    def reopen(alert_id: str, company_id: CompanyId, user: User, db: Db) -> None:
        """Cofnięcie obsługi (np. kliknięte przez pomyłkę) – sprawa wraca na listę."""
        check(db, company_id, user)
        ack = db.get(AlertAck, (company_id, alert_id))
        if ack is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("dashboard.alert_not_found"))
        db.delete(ack)
        db.commit()

    @router.get("/stream")
    async def stream(
        request: Request, company_id: CompanyId, user: User, once: bool = False
    ) -> StreamingResponse:
        database = request.app.state.database
        if database is None:
            raise HTTPException(
                status.HTTP_503_SERVICE_UNAVAILABLE, t("error.database_not_configured")
            )

        def compute_sync() -> dict:
            with database.session() as db:
                return snapshot(request, db, company_id, user)

        def check_sync() -> None:
            with database.session() as db:
                check(db, company_id, user)

        await run_in_threadpool(check_sync)
        interval = getattr(request.app.state, "dashboard_interval", STREAM_INTERVAL_S)
        events = stream_events(
            lambda: run_in_threadpool(compute_sync), interval, request.is_disconnected, once
        )
        return StreamingResponse(
            events,
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )

    return router
