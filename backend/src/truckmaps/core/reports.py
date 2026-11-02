"""Zgłoszenia od kierowców: punkty dostawy (brama, rampa, biuro, godziny przyjęć)
i problemy na drodze (ograniczenie wysokości lub masy, zakaz dla ciężarówek, zamknięta,
wąska droga).

Zgłoszenie robi się jednym dotknięciem (rodzaj + miejsce); godziny przyjęć mają tekst.
Inni kierowcy potwierdzają albo oznaczają zgłoszenie jako nieaktualne – po kilku
głosach „nieaktualne” przewagi zgłoszenie znika. Planer pokazuje je obok trasy: punkty
dostawy przy celu, problemy na drodze wzdłuż trasy.

Ograniczenia ze znaku (wysokość, masa, zakaz dla ciężarówek) są przypisane do drogi OSM
(najbliższa droga przy zgłoszeniu) i liczą się w ocenie trasy: niepotwierdzone – planer
zawsze szuka objazdu (pomarańczowe, „zgłoszenie innych kierowców”); potwierdzone przez
``PERMANENT_SCORE`` różnych kierowców – zapisane na stałe i traktowane jak dane z mapy
(czerwone, pojazd nie przejedzie). Gdy mapa (OSM) ma już to samo ograniczenie na tej
drodze, liczy się mapa.

Kto zgłosił, nie jest pokazywany innym (``mine`` mówi tylko, czy to twoje).
"""

import uuid
from datetime import UTC, datetime, timedelta
from enum import StrEnum
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status
from pydantic import BaseModel, Field, model_validator
from sqlalchemy import (
    BigInteger,
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
from truckmaps.core.restrictions import Kind, Restriction, distance_m
from truckmaps.core.route_analysis import ReportedLimit, SegmentGrid
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
PERMANENT_SCORE = 3
"""Ograniczenie potwierdzone przez tylu kierowców (głosy „aktualne” minus „nieaktualne”,
licząc zgłaszającego) jest zapisywane na stałe – jak dane z mapy."""
NO_WAY = 0
STREET_RADIUS_M = 40.0
"""Ulice do wyboru przy zgłoszeniu ograniczenia – w tym promieniu od miejsca."""
AMBIGUOUS_FACTOR = 3.0
"""Druga ulica bliżej niż tyle razy odległość najbliższej – miejsce niejednoznaczne."""
"""``way_id`` zgłoszenia, przy którym nie znaleziono drogi (nie szukamy ponownie)."""


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
# Ograniczenia ze znaku, które liczą się w ocenie trasy – jak ograniczenia z OSM.
ROAD_LIMITS = {
    ReportKind.HEIGHT_LIMIT: Kind.HEIGHT,
    ReportKind.WEIGHT_LIMIT: Kind.WEIGHT,
    ReportKind.NO_TRUCKS: Kind.HGV_NO,
}


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
    way_id: Mapped[int | None] = mapped_column(BigInteger, index=True)
    """Droga OSM ograniczenia (``NO_WAY`` – nie znaleziono, ``None`` – nie szukano)."""
    permanent_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    """Kiedy ograniczenie potwierdziło ``PERMANENT_SCORE`` kierowców (zapisane na stałe)."""


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
    way_id: int | None = Field(
        default=None, gt=0, description="Ulica ograniczenia wybrana przez kierowcę (droga OSM)"
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
    permanent: bool = Field(
        default=False, description="Ograniczenie potwierdzone przez kilku kierowców – na stałe"
    )
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
        permanent=report.permanent_at is not None,
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


class StreetOut(BaseModel):
    way_id: int
    name: str = Field(description="Nazwa ulicy; pusta – droga bez nazwy")
    distance_m: float


def streets(found: list[tuple[int, str, float]]) -> list[StreetOut]:
    """Ulice do wyboru przy zgłoszeniu: po jednej drodze na nazwę, najbliższe najpierw."""
    seen: dict[str, StreetOut] = {}
    for way_id, name, distance in found:
        if name not in seen or not name:
            seen[name or str(way_id)] = StreetOut(
                way_id=way_id, name=name, distance_m=round(distance)
            )
    return sorted(seen.values(), key=lambda s: s.distance_m)


def unambiguous_way(found: list[tuple[int, str, float]]) -> int:
    """Droga zgłoszenia bez wyboru kierowcy – tylko gdy w pobliżu nie ma innej ulicy.

    Przy skrzyżowaniu znak stoi zwykle na wjeździe w boczną ulicę, a najbliższa bywa ulica
    główna – wtedy ``NO_WAY`` (zgłoszenie widać, ale nie zmienia trasy).
    """
    near = streets([f for f in found if f[2] <= STREET_RADIUS_M])
    if not near:
        return NO_WAY
    if len(near) > 1 and near[1].distance_m <= AMBIGUOUS_FACTOR * max(near[0].distance_m, 1):
        return NO_WAY
    return near[0].way_id


def assign_ways(db: Session, streets_near, geometry: list[tuple[float, float]]) -> None:
    """Przypisuje drogę OSM ograniczeniom zgłoszonym w okolicy trasy bez wybranej ulicy.

    ``streets_near(points, radius_m)`` – drogi przy każdym punkcie; ``None`` (albo brak
    funkcji) – wyszukiwanie niedostępne, spróbujemy następnym razem.
    """
    if len(geometry) < 2 or streets_near is None:
        return
    lons, lats = [p[0] for p in geometry], [p[1] for p in geometry]
    margin = 200 / 111_000
    pending = list(
        db.scalars(
            select(DriverReport).where(
                DriverReport.way_id.is_(None),
                DriverReport.kind.in_([k.value for k in ROAD_LIMITS]),
                DriverReport.score > HIDE_SCORE,
                DriverReport.lat.between(min(lats) - margin, max(lats) + margin),
                DriverReport.lon.between(min(lons) - 2 * margin, max(lons) + 2 * margin),
            )
        )
    )
    if not pending:
        return
    found = streets_near([(r.lon, r.lat) for r in pending], STREET_RADIUS_M)
    if found is None:
        return
    for report, near in zip(pending, found, strict=False):
        report.way_id = unambiguous_way(near)
    db.commit()


def road_limits(db: Session, way_ids) -> dict[int, list[ReportedLimit]]:
    """Ograniczenia zgłoszone przez kierowców na podanych drogach OSM (do oceny trasy)."""
    ids = list(set(way_ids) - {NO_WAY})
    result: dict[int, list[ReportedLimit]] = {}
    for start in range(0, len(ids), 1000):
        query = select(DriverReport).where(
            DriverReport.way_id.in_(ids[start : start + 1000]),
            DriverReport.kind.in_([k.value for k in ROAD_LIMITS]),
            DriverReport.score > HIDE_SCORE,
        )
        for report in db.scalars(query):
            kind = ROAD_LIMITS[ReportKind(report.kind)]
            restriction = Restriction(
                osm_type="way",
                osm_id=report.way_id,
                kind=kind.value,
                value=report.value,
                raw=f"report:{report.kind}={report.value}",
                lat=report.lat,
                lon=report.lon,
            )
            result.setdefault(report.way_id, []).append(
                ReportedLimit(
                    id=report.id,
                    restriction=restriction,
                    permanent=report.permanent_at is not None,
                    confirmations=max(report.score, 1),
                )
            )
    return result


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
            same_way = None in (existing.way_id, data.way_id) or existing.way_id == data.way_id
            if existing.note == data.note and existing.value == data.value and same_way:
                if data.way_id and not existing.way_id:
                    existing.way_id = data.way_id
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

    @router.get("/api/reports/streets")
    def streets_nearby(
        request: Request,
        _user: User,
        lat: Annotated[float, Query(ge=-90, le=90)],
        lon: Annotated[float, Query(ge=-180, le=180)],
    ) -> list[StreetOut]:
        """Ulice przy miejscu zgłoszenia – kierowca wybiera, której dotyczy znak."""
        streets_near = getattr(request.app.state.router, "streets_near", None)
        found = streets_near([(lon, lat)], STREET_RADIUS_M) if streets_near else None
        return streets(found[0]) if found else []

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
    if report.kind in ROAD_LIMITS:
        if report.score >= PERMANENT_SCORE and report.permanent_at is None:
            report.permanent_at = _now()  # potwierdzone przez kilku kierowców – na stałe
        elif report.score <= HIDE_SCORE:
            report.permanent_at = None  # znak zniknął (większość: nieaktualne)
    db.commit()
