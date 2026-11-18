"""Numery domów przy końcach trasy – pomoc przy nieregularnej numeracji.

Tylko na ostatnich kilkuset metrach dojazdu do celu i pierwszych odjazdu ze startu (progi
``house_numbers_end_m`` i ``house_numbers_side_m`` w ``truckmaps.core.thresholds``), nie na
całej trasie. Źródła (``data_pipeline/import_house_numbers.py``): OSM ``addr:housenumber``
i w Polsce punkty adresowe z rejestru państwowego (GUGiK, PRG – dane otwarte).
"""

import math
from typing import Literal

from pydantic import BaseModel
from sqlalchemy import Float, Index, Integer, String, select
from sqlalchemy.orm import Mapped, Session, mapped_column

from truckmaps.core import thresholds
from truckmaps.core.db import Base
from truckmaps.core.restrictions import distance_m
from truckmaps.core.route_analysis import SegmentGrid, cumulative_m

MAX_PER_END = 150
"""Najwięcej numerów przy jednym końcu (najbliższe celowi / startowi)."""


class HouseNumber(Base):
    __tablename__ = "house_numbers"
    __table_args__ = (Index("ix_house_numbers_position", "lat", "lon"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    lat: Mapped[float] = mapped_column(Float)
    lon: Mapped[float] = mapped_column(Float)
    number: Mapped[str] = mapped_column(String(20))
    street: Mapped[str | None] = mapped_column(String(200))
    """Ulica, a w miejscowości bez ulic – nazwa miejscowości."""
    source: Mapped[str] = mapped_column(String(10))
    """``osm`` albo ``prg`` (GUGiK)."""
    source_date: Mapped[str] = mapped_column(String(20))


class HouseNumberOut(BaseModel):
    lat: float
    lon: float
    number: str
    street: str | None = None
    end: Literal["start", "end"]
    """Przy którym końcu trasy: odjazd ze startu albo dojazd do celu."""


def _stretch(geometry: list[tuple[float, float]], length_m: float, from_end: bool):
    """Pierwsze (albo ostatnie) ``length_m`` metrów linii trasy."""
    cumulative = cumulative_m(geometry)
    total = cumulative[-1]
    if from_end:
        first = next((i for i, c in enumerate(cumulative) if c >= total - length_m), 0)
        return geometry[max(first - 1, 0) :]
    last = next((i for i, c in enumerate(cumulative) if c > length_m), len(geometry) - 1)
    return geometry[: last + 1]


def near_route_ends(db: Session, geometry: list[tuple[float, float]]) -> list[HouseNumberOut]:
    """Numery domów przy linii trasy na jej początku i końcu ([lon, lat] jak w geometrii)."""
    if len(geometry) < 2:
        return []
    th = thresholds.current()
    if th.house_numbers_end_m <= 0:
        return []
    found: list[HouseNumberOut] = []
    seen: set[int] = set()
    for end, from_end in (("end", True), ("start", False)):
        line = _stretch(geometry, th.house_numbers_end_m, from_end)
        if len(line) < 2:
            continue
        anchor = line[-1] if from_end else line[0]
        margin_lat = th.house_numbers_side_m / 111_000
        margin_lon = margin_lat / max(math.cos(math.radians(anchor[1])), 0.1)
        lons, lats = [p[0] for p in line], [p[1] for p in line]
        query = select(HouseNumber).where(
            HouseNumber.lat.between(min(lats) - margin_lat, max(lats) + margin_lat),
            HouseNumber.lon.between(min(lons) - margin_lon, max(lons) + margin_lon),
        )
        grid = SegmentGrid(line)
        near = [
            h
            for h in db.scalars(query.limit(20 * MAX_PER_END))
            if h.id not in seen and grid.nearest(h.lon, h.lat, th.house_numbers_side_m) is not None
        ]
        near.sort(key=lambda h: distance_m(anchor[0], anchor[1], h.lon, h.lat))
        for h in near[:MAX_PER_END]:
            seen.add(h.id)
            found.append(
                HouseNumberOut(lat=h.lat, lon=h.lon, number=h.number, street=h.street, end=end)
            )
    return found


# --- Układ PL-1992 (EPSG:2180) → WGS84: punkty adresowe GUGiK -----------------------------
_A = 6378137.0
_F = 1 / 298.257222101  # GRS80
_E2 = _F * (2 - _F)
_K0 = 0.9993
_LON0 = math.radians(19.0)
_FE, _FN = 500_000.0, -5_300_000.0


def _meridian_arc(phi: float) -> float:
    e2, e4, e6 = _E2, _E2**2, _E2**3
    return _A * (
        (1 - e2 / 4 - 3 * e4 / 64 - 5 * e6 / 256) * phi
        - (3 * e2 / 8 + 3 * e4 / 32 + 45 * e6 / 1024) * math.sin(2 * phi)
        + (15 * e4 / 256 + 45 * e6 / 1024) * math.sin(4 * phi)
        - (35 * e6 / 3072) * math.sin(6 * phi)
    )


def wgs84_to_puwg92(lat: float, lon: float) -> tuple[float, float]:
    """(wschód x, północ y) w PL-1992 – odwrotność :func:`puwg92_to_wgs84` (testy, sprawdzanie)."""
    phi, lam = math.radians(lat), math.radians(lon)
    ep2 = _E2 / (1 - _E2)
    n = _A / math.sqrt(1 - _E2 * math.sin(phi) ** 2)
    t, c = math.tan(phi) ** 2, ep2 * math.cos(phi) ** 2
    a = (lam - _LON0) * math.cos(phi)
    x = (
        _K0
        * n
        * (a + (1 - t + c) * a**3 / 6 + (5 - 18 * t + t**2 + 72 * c - 58 * ep2) * a**5 / 120)
    )
    y = _K0 * (
        _meridian_arc(phi)
        + n
        * math.tan(phi)
        * (
            a**2 / 2
            + (5 - t + 9 * c + 4 * c**2) * a**4 / 24
            + (61 - 58 * t + t**2 + 600 * c - 330 * ep2) * a**6 / 720
        )
    )
    return x + _FE, y + _FN


def puwg92_to_wgs84(x: float, y: float) -> tuple[float, float]:
    """(lat, lon) z PL-1992: ``x`` – wschód (easting), ``y`` – północ (northing)."""
    ep2 = _E2 / (1 - _E2)
    m = (y - _FN) / _K0
    mu = m / (_A * (1 - _E2 / 4 - 3 * _E2**2 / 64 - 5 * _E2**3 / 256))
    e1 = (1 - math.sqrt(1 - _E2)) / (1 + math.sqrt(1 - _E2))
    phi1 = (
        mu
        + (3 * e1 / 2 - 27 * e1**3 / 32) * math.sin(2 * mu)
        + (21 * e1**2 / 16 - 55 * e1**4 / 32) * math.sin(4 * mu)
        + (151 * e1**3 / 96) * math.sin(6 * mu)
        + (1097 * e1**4 / 512) * math.sin(8 * mu)
    )
    n1 = _A / math.sqrt(1 - _E2 * math.sin(phi1) ** 2)
    r1 = _A * (1 - _E2) / (1 - _E2 * math.sin(phi1) ** 2) ** 1.5
    t1, c1 = math.tan(phi1) ** 2, ep2 * math.cos(phi1) ** 2
    d = (x - _FE) / (n1 * _K0)
    lat = phi1 - (n1 * math.tan(phi1) / r1) * (
        d**2 / 2
        - (5 + 3 * t1 + 10 * c1 - 4 * c1**2 - 9 * ep2) * d**4 / 24
        + (61 + 90 * t1 + 298 * c1 + 45 * t1**2 - 252 * ep2 - 3 * c1**2) * d**6 / 720
    )
    lon = _LON0 + (
        d
        - (1 + 2 * t1 + c1) * d**3 / 6
        + (5 - 2 * c1 + 28 * t1 - 3 * c1**2 + 8 * ep2 + 24 * t1**2) * d**5 / 120
    ) / math.cos(phi1)
    return math.degrees(lat), math.degrees(lon)
