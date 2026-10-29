"""Zgłoszenia od kierowców: punkty dostawy (brama, rampa, biuro, godziny przyjęć)
i problemy na drodze (ograniczenie wysokości lub masy, zakaz dla ciężarówek, zamknięta,
wąska droga).

Zgłoszenie robi się jednym dotknięciem (rodzaj + miejsce); godziny przyjęć mają tekst.
Inni kierowcy potwierdzają albo oznaczają zgłoszenie jako nieaktualne – po kilku
głosach „nieaktualne” przewagi zgłoszenie znika. Zgłoszenia nie zmieniają oceny trasy
(to niesprawdzone dane) – planer pokazuje je obok: punkty dostawy przy celu, problemy
na drodze wzdłuż trasy.

Kto zgłosił, nie jest pokazywany innym (``mine`` mówi tylko, czy to twoje).
"""

import uuid
from datetime import UTC, datetime, timedelta
from enum import StrEnum
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from pydantic import BaseModel, Field, model_validator
from sqlalchemy import (
    DateTime,
    Float,
    ForeignKey,
    Index,
    Integer,
    String,
    UniqueConstraint,
    func,
    select,
)
from sqlalchemy.orm import Mapped, Session, mapped_column

from truckmaps.core.db import Base, get_session
from truckmaps.core.i18n import t
from truckmaps.core.restrictions import distance_m
from truckmaps.core.route_analysis import SegmentGrid
from truckmaps.sdk import Principal

# Punkty dostawy przy celu: w tym promieniu od celu trasy.
NEAR_DESTINATION_M = 500.0
# Problem na drodze „na trasie”, gdy leży najwyżej tyle od linii trasy.
ON_ROUTE_M = 40.0
NEARBY_MAX_M = 5000.0
# Zgłoszenie znika, gdy „nieaktualne” ma tyle głosów więcej niż „aktualne” (licząc zgłaszającego).
HIDE_SCORE = -2
DAILY_LIMIT = 100
"""Najwięcej zgłoszeń jednego konta na dobę (ochrona przed zalewem)."""
SAME_PLACE_M = 15.0
"""To samo zgłoszenie tego samego rodzaju bliżej niż tyle = potwierdzenie, nie nowe."""


class ReportKind(StrEnum):
    GATE = "gate"
    RAMP = "ramp"
    OFFICE = "office"
    WAITING_AREA = "waiting_area"
    HOURS = "hours"
    HEIGHT_LIMIT = "height_limit"
    WEIGHT_LIMIT = "weight_limit"
    NO_TRUCKS = "no_trucks"
    ROAD_CLOSED = "road_closed"
    NARROW = "narrow"
    OTHER = "other"


DELIVERY_KINDS = {
    ReportKind.GATE,
    ReportKind.RAMP,
    ReportKind.OFFICE,
    ReportKind.WAITING_AREA,
    ReportKind.HOURS,
}
NEEDS_NOTE = {ReportKind.HOURS, ReportKind.OTHER}
NEEDS_VALUE = {ReportKind.HEIGHT_LIMIT, ReportKind.WEIGHT_LIMIT}


def _now() -> datetime:
    return datetime.now(UTC)


class DriverReport(Base):
    __tablename__ = "driver_reports"
    __table_args__ = (Index("ix_driver_reports_lat_lon", "lat", "lon"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    subject: Mapped[str] = mapped_column(String(255), index=True)
    kind: Mapped[str] = mapped_column(String(20))
    lat: Mapped[float] = mapped_column(Float)
    lon: Mapped[float] = mapped_column(Float)
    note: Mapped[str] = mapped_column(String(300), default="")
    value: Mapped[float | None] = mapped_column(Float)
    score: Mapped[int] = mapped_column(Integer, default=1)
    """Głosy „aktualne” minus „nieaktualne”; zgłaszający liczy się jako pierwsze „aktualne”."""
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    confirmed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class ReportVote(Base):
    __tablename__ = "driver_report_votes"
    __table_args__ = (UniqueConstraint("report_id", "subject"),)

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    report_id: Mapped[str] = mapped_column(ForeignKey("driver_reports.id", ondelete="CASCADE"))
    subject: Mapped[str] = mapped_column(String(255))
    up: Mapped[bool]
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class ReportIn(BaseModel):
    kind: ReportKind
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)
    note: str = Field(default="", max_length=300, description="Np. godziny przyjęć „pn–pt 6–14”")
    value: float | None = Field(
        default=None, gt=0, lt=100, description="Np. wysokość 3,5 m, masa 12 t"
    )

    @model_validator(mode="after")
    def _complete(self) -> "ReportIn":
        self.note = self.note.strip()
        if self.kind in NEEDS_NOTE and not self.note:
            raise ValueError(t("error.report_needs_note"))
        if self.kind in NEEDS_VALUE and self.value is None:
            raise ValueError(t("error.report_needs_value"))
        return self


class ReportOut(BaseModel):
    id: str
    kind: ReportKind
    label: str = Field(description="Rodzaj w języku zapytania, np. „Rampa”")
    message: str = Field(description="Do pokazania, np. „Godziny przyjęć: pn–pt 6–14”")
    lat: float
    lon: float
    note: str
    value: float | None
    score: int
    confirmed_at: datetime
    mine: bool = False
    distance_m: float | None = None
    km: float | None = Field(default=None, description="Miejsce na trasie (problemy na drodze)")


class VoteIn(BaseModel):
    up: bool = Field(description="true – nadal aktualne, false – nieaktualne")


def describe(report: DriverReport) -> str:
    label = t(f"report.{report.kind}")
    if report.kind in NEEDS_VALUE and report.value is not None:
        unit = "m" if report.kind == ReportKind.HEIGHT_LIMIT else "t"
        label = t("report.with_value", label=label, value=report.value, unit=unit)
    return t("report.with_note", label=label, note=report.note) if report.note else label


def to_out(report: DriverReport, user: Principal | None = None, **extra) -> ReportOut:
    return ReportOut(
        id=report.id,
        kind=ReportKind(report.kind),
        label=t(f"report.{report.kind}"),
        message=describe(report),
        lat=report.lat,
        lon=report.lon,
        note=report.note,
        value=report.value,
        score=report.score,
        confirmed_at=report.confirmed_at,
        mine=user is not None and report.subject == user.subject,
        **extra,
    )


def _in_box(lat: float, lon: float, radius_m: float):
    margin = radius_m / 111_000
    return select(DriverReport).where(
        DriverReport.score > HIDE_SCORE,
        DriverReport.lat.between(lat - margin, lat + margin),
        DriverReport.lon.between(lon - 2 * margin, lon + 2 * margin),
    )


def nearby(
    db: Session, lat: float, lon: float, radius_m: float, kinds: set[ReportKind] | None = None
) -> list[tuple[DriverReport, float]]:
    """Aktywne zgłoszenia w promieniu, od najbliższego."""
    found = [
        (r, distance_m(lon, lat, r.lon, r.lat)) for r in db.scalars(_in_box(lat, lon, radius_m))
    ]
    return sorted(
        ((r, d) for r, d in found if d <= radius_m and (kinds is None or r.kind in kinds)),
        key=lambda item: item[1],
    )


def near_destination(db: Session, lat: float, lon: float, user: Principal) -> list[ReportOut]:
    """Punkty dostawy przy celu trasy (brama, rampa, biuro, godziny przyjęć)."""
    return [
        to_out(r, user, distance_m=round(d))
        for r, d in nearby(db, lat, lon, NEAR_DESTINATION_M, DELIVERY_KINDS)
    ]


def along_route(
    db: Session, geometry: list[tuple[float, float]], user: Principal
) -> list[ReportOut]:
    """Problemy na drodze zgłoszone przez kierowców, leżące na linii trasy."""
    if len(geometry) < 2:
        return []
    lons, lats = [p[0] for p in geometry], [p[1] for p in geometry]
    margin = ON_ROUTE_M / 111_000
    query = select(DriverReport).where(
        DriverReport.score > HIDE_SCORE,
        DriverReport.kind.not_in([k.value for k in DELIVERY_KINDS]),
        DriverReport.lat.between(min(lats) - margin, max(lats) + margin),
        DriverReport.lon.between(min(lons) - 2 * margin, max(lons) + 2 * margin),
    )
    candidates = list(db.scalars(query))
    if not candidates:
        return []
    grid = SegmentGrid(geometry)
    cumulative = [0.0]
    for (lon1, lat1), (lon2, lat2) in zip(geometry, geometry[1:], strict=False):
        cumulative.append(cumulative[-1] + distance_m(lon1, lat1, lon2, lat2))
    found = []
    for report in candidates:
        index = grid.nearest(report.lon, report.lat, ON_ROUTE_M)
        if index is not None:
            # Zgłoszenie leży tuż przy odcinku – odległość od jego początku wystarczy.
            start_lon, start_lat = geometry[index]
            along = cumulative[index] + distance_m(start_lon, start_lat, report.lon, report.lat)
            found.append(to_out(report, user, km=round(along / 1000, 1)))
    return sorted(found, key=lambda r: r.km or 0)


def build_router(current_user) -> APIRouter:
    router = APIRouter(tags=["reports"])
    User = Annotated[Principal, Depends(current_user)]
    Db = Annotated[Session, Depends(get_session)]

    def load(db: Session, report_id: str) -> DriverReport:
        report = db.get(DriverReport, report_id)
        if report is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("error.report_not_found"))
        return report

    @router.post("/api/reports", status_code=status.HTTP_201_CREATED)
    def create(data: ReportIn, user: User, db: Db, response: Response) -> ReportOut:
        """Nowe zgłoszenie; to samo miejsce i rodzaj zgłoszone już przez kogoś = potwierdzenie."""
        today = db.scalar(
            select(func.count())
            .select_from(DriverReport)
            .where(
                DriverReport.subject == user.subject,
                DriverReport.created_at >= _now() - timedelta(days=1),
            )
        )
        if today >= DAILY_LIMIT:
            raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, t("error.report_limit"))
        for existing, _ in nearby(db, data.lat, data.lon, SAME_PLACE_M, {data.kind}):
            if existing.note == data.note and existing.value == data.value:
                if existing.subject != user.subject:
                    _vote(db, existing, user, up=True)
                response.status_code = status.HTTP_200_OK
                return to_out(existing, user)
        report = DriverReport(subject=user.subject, **data.model_dump())
        db.add(report)
        db.commit()
        return to_out(report, user)

    @router.get("/api/reports")
    def list_nearby(
        user: User,
        db: Db,
        lat: Annotated[float, Query(ge=-90, le=90)],
        lon: Annotated[float, Query(ge=-180, le=180)],
        radius_m: Annotated[float, Query(gt=0, le=NEARBY_MAX_M)] = 1000,
    ) -> list[ReportOut]:
        return [to_out(r, user, distance_m=round(d)) for r, d in nearby(db, lat, lon, radius_m)]

    @router.get("/api/reports/mine")
    def mine(user: User, db: Db) -> list[ReportOut]:
        rows = db.scalars(
            select(DriverReport)
            .where(DriverReport.subject == user.subject)
            .order_by(DriverReport.created_at.desc())
            .limit(200)
        )
        return [to_out(r, user) for r in rows]

    @router.post("/api/reports/{report_id}/vote")
    def vote(report_id: str, data: VoteIn, user: User, db: Db) -> ReportOut:
        report = load(db, report_id)
        if report.subject == user.subject:
            raise HTTPException(status.HTTP_409_CONFLICT, t("error.report_own_vote"))
        _vote(db, report, user, data.up)
        return to_out(report, user)

    @router.delete("/api/reports/{report_id}", status_code=status.HTTP_204_NO_CONTENT)
    def delete(report_id: str, user: User, db: Db) -> None:
        report = load(db, report_id)
        if report.subject != user.subject:
            raise HTTPException(status.HTTP_403_FORBIDDEN, t("error.report_not_yours"))
        db.delete(report)
        db.commit()

    return router


def _vote(db: Session, report: DriverReport, user: Principal, up: bool) -> None:
    """Głos konta (zmiana zdania zastępuje poprzedni głos)."""
    previous = db.scalar(
        select(ReportVote).where(
            ReportVote.report_id == report.id, ReportVote.subject == user.subject
        )
    )
    if previous is not None:
        if previous.up == up:
            return
        report.score -= 1 if previous.up else -1
        previous.up = up
    else:
        db.add(ReportVote(report_id=report.id, subject=user.subject, up=up))
    report.score += 1 if up else -1
    if up:
        report.confirmed_at = _now()
    db.commit()
