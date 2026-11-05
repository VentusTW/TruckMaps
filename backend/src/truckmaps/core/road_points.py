"""Punkty i odcinki z OSM do ostrzeżeń w nawigacji (nie ograniczenia dla pojazdu).

Przejazdy kolejowe, fotoradary, sygnalizacja świetlna, odcinkowy pomiar prędkości i zakazy
wyprzedzania. Import: ``data_pipeline/import_road_points.py``. Do trasy trafiają te, które
leżą na jej linii – z kilometrem od startu (nawigacja liczy z nich odległości).
"""

from enum import StrEnum

from pydantic import BaseModel
from sqlalchemy import BigInteger, Float, Index, String, Text, or_, select
from sqlalchemy.orm import Mapped, Session, mapped_column

from truckmaps.core.db import Base
from truckmaps.core.polyline import decode_polyline6
from truckmaps.core.restrictions import (
    QUERY_BATCH,
    box_overlaps,
    distance_m,
    route_chunks,
    span_index,
)
from truckmaps.core.route_analysis import cumulative_m, segment_grid


class PointKind(StrEnum):
    LEVEL_CROSSING = "level_crossing"
    SPEED_CAMERA = "speed_camera"
    TRAFFIC_SIGNALS = "traffic_signals"
    AVERAGE_SPEED = "average_speed"
    """Odcinkowy pomiar prędkości: od punktu ``from`` do ``to`` relacji ``enforcement``."""
    NO_OVERTAKING = "no_overtaking"
    """Zakaz wyprzedzania (``overtaking:hgv=no`` albo ``overtaking=no``) – odcinek drogi."""


class RoadPoint(Base):
    __tablename__ = "road_points"
    __table_args__ = (
        Index("ix_road_points_bbox", "min_lat", "min_lon"),
        span_index("ix_road_points_span"),
    )

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    osm_type: Mapped[str] = mapped_column(String(8))
    osm_id: Mapped[int] = mapped_column(BigInteger)
    kind: Mapped[str] = mapped_column(String(20))
    lat: Mapped[float] = mapped_column(Float)
    lon: Mapped[float] = mapped_column(Float)
    end_lat: Mapped[float | None] = mapped_column(Float)
    end_lon: Mapped[float | None] = mapped_column(Float)
    """Koniec odcinkowego pomiaru prędkości."""
    line: Mapped[str | None] = mapped_column(Text)
    """Przebieg drogi z zakazem wyprzedzania (polilinia 1e-6, [lon, lat])."""
    value: Mapped[float | None] = mapped_column(Float)
    """Ograniczenie prędkości przy fotoradarze / na odcinku pomiaru [km/h]."""
    min_lat: Mapped[float] = mapped_column(Float)
    min_lon: Mapped[float] = mapped_column(Float)
    max_lat: Mapped[float] = mapped_column(Float)
    max_lon: Mapped[float] = mapped_column(Float)
    source: Mapped[str] = mapped_column(String(30))
    source_date: Mapped[str] = mapped_column(String(20))


class RoadEvent(BaseModel):
    kind: str
    km: float
    end_km: float | None = None
    """Koniec odcinka (pomiar odcinkowy, zakaz wyprzedzania)."""
    lat: float
    lon: float
    speed_kmh: float | None = None


# Jak blisko linii trasy musi leżeć punkt; sygnalizacja – ciaśniej (stoi też przy drogach obok).
ON_ROUTE_M = {PointKind.TRAFFIC_SIGNALS: 12.0}
DEFAULT_ON_ROUTE_M = 25.0
LINE_ON_ROUTE_M = 15.0
# Kawałki zakazu wyprzedzania (drogi OSM dzielone na odcinki) łączone przy przerwie do tylu m.
MERGE_GAP_M = 150.0
MIN_LINE_M = 100.0


def parse_speed(raw: str | None) -> float | None:
    """„70”, „70 km/h”, „50 mph” → km/h; inne wartości – brak."""
    if not raw:
        return None
    text = raw.strip().lower()
    mph = text.endswith("mph")
    number = text.removesuffix("mph").removesuffix("km/h").strip()
    if not number.replace(".", "", 1).isdigit():
        return None
    value = float(number)
    return round(value * 1.609) if mph else value


def _candidates(db: Session, geometry: list[tuple[float, float]]) -> list[RoadPoint]:
    margin_lat = DEFAULT_ON_ROUTE_M / 111_000
    margin_lon = 2 * margin_lat
    boxes = []
    for chunk in route_chunks(geometry):
        lons, lats = [p[0] for p in chunk], [p[1] for p in chunk]
        boxes.append(
            box_overlaps(
                RoadPoint,
                min(lats) - margin_lat,
                max(lats) + margin_lat,
                min(lons) - margin_lon,
                max(lons) + margin_lon,
            )
        )
    found: dict[int, RoadPoint] = {}
    for start in range(0, len(boxes), QUERY_BATCH):
        for point in db.scalars(select(RoadPoint).where(or_(*boxes[start : start + QUERY_BATCH]))):
            found[point.id] = point
    return list(found.values())


def along_route(db: Session, geometry: list[tuple[float, float]]) -> list[RoadEvent]:
    """Punkty i odcinki leżące na linii trasy, po kolei od startu."""
    if len(geometry) < 2:
        return []
    candidates = _candidates(db, geometry)
    if not candidates:
        return []
    grid = segment_grid(geometry)
    cumulative = cumulative_m(geometry)

    def along(lon: float, lat: float, max_m: float) -> float | None:
        index = grid.nearest(lon, lat, max_m)
        if index is None:
            return None
        start_lon, start_lat = geometry[index]
        return cumulative[index] + distance_m(start_lon, start_lat, lon, lat)

    events: list[RoadEvent] = []
    lines: list[tuple[float, float, RoadPoint]] = []
    for point in candidates:
        if point.kind == PointKind.NO_OVERTAKING:
            alongs = [
                a
                for lon, lat in decode_polyline6(point.line or "")
                if (a := along(lon, lat, LINE_ON_ROUTE_M)) is not None
            ]
            if len(alongs) >= 2:
                lines.append((min(alongs), max(alongs), point))
            continue
        start = along(point.lon, point.lat, ON_ROUTE_M.get(point.kind, DEFAULT_ON_ROUTE_M))
        if start is None:
            continue
        end = None
        if point.kind == PointKind.AVERAGE_SPEED:
            if point.end_lat is None or point.end_lon is None:
                continue
            end = along(point.end_lon, point.end_lat, DEFAULT_ON_ROUTE_M)
            if end is None or end <= start:
                continue  # pomiar w drugą stronę albo poza trasą
        events.append(
            RoadEvent(
                kind=point.kind,
                km=round(start / 1000, 3),
                end_km=None if end is None else round(end / 1000, 3),
                lat=point.lat,
                lon=point.lon,
                speed_kmh=point.value,
            )
        )
    # Zakaz wyprzedzania: sąsiednie kawałki drogi jako jeden odcinek.
    merged: list[list] = []
    for start, end, point in sorted(lines, key=lambda item: item[0]):
        if merged and start - merged[-1][1] <= MERGE_GAP_M:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end, point])
    for start, end, _point in merged:
        if end - start >= MIN_LINE_M:
            lon, lat = _point_at(geometry, cumulative, start)
            events.append(
                RoadEvent(
                    kind=PointKind.NO_OVERTAKING,
                    km=round(start / 1000, 3),
                    end_km=round(end / 1000, 3),
                    lat=lat,
                    lon=lon,
                )
            )
    return sorted(events, key=lambda e: e.km)


def _point_at(
    geometry: list[tuple[float, float]], cumulative: list[float], along_m: float
) -> tuple[float, float]:
    for i in range(1, len(cumulative)):
        if cumulative[i] >= along_m:
            length = cumulative[i] - cumulative[i - 1]
            t = 0.0 if length == 0 else (along_m - cumulative[i - 1]) / length
            (lon1, lat1), (lon2, lat2) = geometry[i - 1], geometry[i]
            return lon1 + t * (lon2 - lon1), lat1 + t * (lat2 - lat1)
    return geometry[-1]
