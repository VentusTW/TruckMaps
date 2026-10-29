"""Korytarz danych dla telefonu: ograniczenia w pasie wokół trasy, ocenione dla pojazdu.

Telefon dostaje go razem z trasą i dzięki niemu działa bez zasięgu: gdy kierowca zjedzie
z trasy w drogę, której pojazd nie przejedzie, alarm włącza się lokalnie (``check_position``).
Przebiegi dróg są polilinami 1e-6, a odpowiedź – kompresowana (gzip), więc paczka dla trasy
kilkusetkilometrowej ma zwykle kilkadziesiąt kB.
"""

from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import and_, or_, select
from sqlalchemy.orm import Session

from truckmaps.core.db import get_session
from truckmaps.core.i18n import t
from truckmaps.core.polyline import decode_polyline6, encode_polyline6
from truckmaps.core.restrictions import ROAD_CONTEXT, Kind, Restriction, distance_m
from truckmaps.core.route_analysis import (
    Level,
    _compare,
    _distance_to_segment,
    _limit_label,
    _SegmentGrid,
    conditional_findings,
)
from truckmaps.core.vehicles import VehicleIn, VehicleOut, load_owned
from truckmaps.sdk import Principal

CORRIDOR_VERSION = 1
DEFAULT_BUFFER_M = 500.0
# Trasa dzielona na kawałki – zapytanie o prostokąty wzdłuż trasy zamiast jednego wielkiego.
QUERY_CHUNK_KM = 10.0
QUERY_BATCH = 40
# Pozycja dalej od trasy niż tyle = kierowca zjechał z trasy.
OFF_ROUTE_M = 40.0
# Pozycja bliżej drogi nieprzejezdnej niż tyle = kierowca na niej jest.
ON_ROAD_M = 15.0
_LEVELS = [level.label for level in Level]


class CorridorItem(BaseModel):
    id: int
    level: str
    """Ocena dla tego pojazdu: red (nie przejedzie), orange, yellow."""
    kind: str
    message: str
    limit: str | None = None
    line: str
    """Przebieg drogi albo położenie punktu (polilinia 1e-6, [lon, lat])."""


class Corridor(BaseModel):
    version: int = CORRIDOR_VERSION
    created: datetime
    buffer_m: float
    vehicle: VehicleIn
    route: str
    """Linia trasy (polilinia 1e-6)."""
    items: list[CorridorItem]


class CorridorRequest(BaseModel):
    vehicle_id: str
    route: str = Field(description="Linia trasy (polilinia 1e-6) – np. z odpowiedzi /api/routes")
    buffer_m: float = Field(default=DEFAULT_BUFFER_M, ge=50, le=2000)


class PositionCheck(BaseModel):
    on_route: bool
    alarm: CorridorItem | None = None
    """Droga nieprzejezdna dla pojazdu, na której jest pozycja (poza trasą)."""


def build_corridor(
    db: Session, route: list[tuple[float, float]], vehicle: VehicleIn, buffer_m: float
) -> Corridor:
    grid = _SegmentGrid(route, cell=_cell(buffer_m))
    items = []
    for restriction in _candidates(db, route, buffer_m):
        if restriction.kind in ROAD_CONTEXT:
            continue
        if restriction.kind == Kind.CONDITIONAL:
            # Stałe warunki (np. zakaz dla pojazdów powyżej 7,5 t); czasowe ocenia planer.
            found = conditional_findings(restriction, vehicle)
            finding = max(found, key=lambda f: f[0]) if found else None
        else:
            finding = _compare(restriction, vehicle)
        if finding is None:
            continue
        points = (
            decode_polyline6(restriction.line)
            if restriction.line
            else [(restriction.lon, restriction.lat)]
        )
        if not any(grid.nearest(lon, lat, buffer_m) is not None for lon, lat in points):
            continue
        level, message = finding
        items.append(
            CorridorItem(
                id=restriction.id,
                level=level.label,
                kind=restriction.kind,
                message=message,
                limit=_limit_label(restriction),
                line=encode_polyline6(points),
            )
        )
    items.sort(key=lambda item: -_LEVELS.index(item.level))
    return Corridor(
        created=datetime.now(UTC),
        buffer_m=buffer_m,
        vehicle=VehicleIn.model_validate(vehicle, from_attributes=True),
        route=encode_polyline6(route),
        items=items,
    )


def check_position(corridor: Corridor, lon: float, lat: float) -> PositionCheck:
    """Bez sieci: czy pozycja jest na trasie, a jeśli nie – czy na drodze nieprzejezdnej.

    Na trasie alarmu nie ma (planowanie omija takie drogi). Poza trasą alarm daje najbliższa
    droga czerwona w promieniu ``ON_ROAD_M``.
    """
    route = decode_polyline6(corridor.route)
    if _SegmentGrid(route).nearest(lon, lat, OFF_ROUTE_M) is not None:
        return PositionCheck(on_route=True)
    best, alarm = ON_ROAD_M, None
    for item in corridor.items:
        if item.level != Level.RED.label:
            continue
        points = decode_polyline6(item.line)
        distance = (
            distance_m(lon, lat, *points[0])
            if len(points) == 1
            else _distance_to_line(lon, lat, points)
        )
        if distance <= best:
            best, alarm = distance, item
    return PositionCheck(on_route=False, alarm=alarm)


def _distance_to_line(lon: float, lat: float, points: list[tuple[float, float]]) -> float:
    grid = _SegmentGrid(points)
    index = grid.nearest(lon, lat, ON_ROAD_M)
    if index is None:
        return float("inf")
    return _distance_to_segment(lon, lat, points[index], points[index + 1])


def _cell(buffer_m: float) -> float:
    # Komórka siatki większa niż bufor także w długości geograficznej (cos 60° = 0,5).
    return buffer_m / 111_000 / 0.5


def _candidates(
    db: Session, route: list[tuple[float, float]], buffer_m: float
) -> list[Restriction]:
    """Ograniczenia, których prostokąt nachodzi na pas wokół któregoś kawałka trasy."""
    boxes = []
    for chunk in _route_chunks(route, QUERY_CHUNK_KM):
        lons, lats = [p[0] for p in chunk], [p[1] for p in chunk]
        margin_lat, margin_lon = buffer_m / 111_000, buffer_m / 111_000 / 0.5
        boxes.append(
            and_(
                Restriction.min_lat <= max(lats) + margin_lat,
                Restriction.max_lat >= min(lats) - margin_lat,
                Restriction.min_lon <= max(lons) + margin_lon,
                Restriction.max_lon >= min(lons) - margin_lon,
            )
        )
    found: dict[int, Restriction] = {}
    for start in range(0, len(boxes), QUERY_BATCH):
        for restriction in db.scalars(
            select(Restriction).where(or_(*boxes[start : start + QUERY_BATCH]))
        ):
            found[restriction.id] = restriction
    return list(found.values())


def _route_chunks(route: list[tuple[float, float]], max_km: float):
    start, length = 0, 0.0
    for i in range(1, len(route)):
        length += distance_m(*route[i - 1], *route[i])
        if length >= max_km * 1000:
            yield route[start : i + 1]
            start, length = i, 0.0
    if start < len(route) - 1 or len(route) == 1:
        yield route[start:]


def build_router(current_user) -> APIRouter:
    router = APIRouter(prefix="/api/corridor", tags=["corridor"])
    User = Annotated[Principal, Depends(current_user)]
    Db = Annotated[Session, Depends(get_session)]

    @router.post("")
    def corridor(data: CorridorRequest, user: User, db: Db) -> Corridor:
        """Korytarz danych dla trasy i pojazdu – do pracy telefonu bez zasięgu."""
        vehicle = VehicleOut.model_validate(load_owned(db, data.vehicle_id, user))
        try:
            route = decode_polyline6(data.route)
        except (IndexError, ValueError) as exc:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY, t("error.bad_route_line")
            ) from exc
        if len(route) < 2:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, t("error.route_too_short"))
        return build_corridor(db, route, vehicle, data.buffer_m)

    @router.post("/position")
    def position(corridor: Corridor, lon: float, lat: float, user: User) -> PositionCheck:
        """To samo sprawdzenie, które telefon robi bez sieci (do testów i podglądu)."""
        return check_position(corridor, lon, lat)

    return router
