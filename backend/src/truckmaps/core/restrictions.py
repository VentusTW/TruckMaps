"""Ograniczenia na drogach (wysokość, masa, szerokość…) z OSM i innych źródeł.

Ograniczenia na drogach (ways) są kluczowane identyfikatorem drogi z OSM – Valhalla
zwraca go dla każdego odcinka trasy. Ograniczenia w punktach (np. bramka
ograniczająca wysokość) mają współrzędne i są dopasowywane do trasy po odległości.
"""

import math
import re
from collections.abc import Iterable
from enum import StrEnum

from sqlalchemy import BigInteger, Float, Index, String, Text, and_, or_, select
from sqlalchemy.orm import Mapped, Session, mapped_column

from truckmaps.core.db import Base


class Kind(StrEnum):
    HEIGHT = "height"
    WEIGHT = "weight"
    WEIGHT_RATING = "weight_rating"
    """Ograniczenie dopuszczalnej masy całkowitej (DMC), a nie masy rzeczywistej."""
    AXLE_LOAD = "axle_load"
    WIDTH = "width"
    LENGTH = "length"
    HGV_NO = "hgv_no"
    HGV_DESTINATION = "hgv_destination"
    CONDITIONAL = "conditional"
    """Ograniczenie warunkowe (``*:conditional``) – w ``raw`` cały tag, ocena: ``conditional``."""
    # Cechy dróg lokalnych (nie ograniczenia) – pomagają ocenić, czy zestaw się zmieści.
    HGV_DESIGNATED = "hgv_designated"
    ROAD_WIDTH = "road_width"
    BAD_SURFACE = "bad_surface"
    INDUSTRIAL_AREA = "industrial_area"


# Cechy, które nie są ograniczeniami do porównania z wymiarami pojazdu.
ROAD_CONTEXT = {Kind.HGV_DESIGNATED, Kind.ROAD_WIDTH, Kind.BAD_SURFACE, Kind.INDUSTRIAL_AREA}

# Drogi lokalne, dla których zapisujemy szerokość, nawierzchnię i otoczenie.
MINOR_HIGHWAYS = {"residential", "service", "unclassified", "living_street", "track"}
BAD_SMOOTHNESS = {"bad", "very_bad", "horrible", "very_horrible", "impassable"}


class Restriction(Base):
    __tablename__ = "road_restrictions"
    __table_args__ = (
        Index("ix_road_restrictions_osm", "osm_type", "osm_id"),
        Index("ix_road_restrictions_bbox", "min_lat", "min_lon"),
    )

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    osm_type: Mapped[str] = mapped_column(String(4))
    osm_id: Mapped[int] = mapped_column(BigInteger)
    kind: Mapped[str] = mapped_column(String(20))
    value: Mapped[float | None] = mapped_column(Float)
    """Metry (wysokość, szerokość, długość) albo tony (masa, nacisk osi)."""
    raw: Mapped[str] = mapped_column(String(255))
    lat: Mapped[float | None] = mapped_column(Float)
    lon: Mapped[float | None] = mapped_column(Float)
    line: Mapped[str | None] = mapped_column(Text)
    """Przebieg drogi (polilinia 1e-6) – do korytarza danych dla telefonu."""
    min_lat: Mapped[float | None] = mapped_column(Float)
    min_lon: Mapped[float | None] = mapped_column(Float)
    max_lat: Mapped[float | None] = mapped_column(Float)
    max_lon: Mapped[float | None] = mapped_column(Float)
    """Prostokąt otaczający drogę albo punkt – szybkie wyszukiwanie wzdłuż trasy."""
    source: Mapped[str] = mapped_column(String(30))
    source_date: Mapped[str] = mapped_column(String(20))


# Tagi OSM → rodzaj ograniczenia. Wartość "physical" (rzeczywisty prześwit) ma
# pierwszeństwo przed wartością ze znaku, jeśli obie występują.
LENGTH_TAGS = {
    "maxheight:physical": Kind.HEIGHT,
    "maxheight": Kind.HEIGHT,
    "maxwidth:physical": Kind.WIDTH,
    "maxwidth": Kind.WIDTH,
    "maxlength": Kind.LENGTH,
}
WEIGHT_TAGS = {
    "maxweight": Kind.WEIGHT,
    "maxweight:hgv": Kind.WEIGHT,
    "maxweightrating": Kind.WEIGHT_RATING,
    "maxweightrating:hgv": Kind.WEIGHT_RATING,
    "maxaxleload": Kind.AXLE_LOAD,
}
# Ograniczenia warunkowe (np. zakaz w godzinach) istotne dla ciężarówek – tag → rodzaj
# ograniczenia, którego dotyczy wartość ("no", "destination" albo liczba).
CONDITIONAL_TAGS = {
    "hgv:conditional": Kind.HGV_NO,
    "hgv:forward:conditional": Kind.HGV_NO,
    "hgv:backward:conditional": Kind.HGV_NO,
    "goods:conditional": Kind.HGV_NO,
    "motor_vehicle:conditional": Kind.HGV_NO,
    "access:conditional": Kind.HGV_NO,
    "maxweight:conditional": Kind.WEIGHT,
    "maxweightrating:conditional": Kind.WEIGHT_RATING,
    "maxaxleload:conditional": Kind.AXLE_LOAD,
    "maxlength:conditional": Kind.LENGTH,
    "maxheight:conditional": Kind.HEIGHT,
}

RESTRICTION_KEYS = (
    *LENGTH_TAGS, *WEIGHT_TAGS, *CONDITIONAL_TAGS, "hgv", "width", "smoothness",
)  # fmt: skip

_NUMBER = r"(\d+(?:[.,]\d+)?)"
_NO_VALUE = {"default", "none", "unsigned", "below_default", "no_sign", "no_indications"}


def parse_length(raw: str) -> float | None:
    """Długość w metrach z tagu OSM: "3.8", "3,8 m", "380 cm", "12'6\""; brak liczby → None."""
    text = raw.strip().lower()
    if text in _NO_VALUE:
        return None
    feet = re.fullmatch(r"(\d+)\s*'\s*(?:(\d+)\s*\")?", text)
    if feet:
        return round(int(feet[1]) * 0.3048 + int(feet[2] or 0) * 0.0254, 2)
    match = re.fullmatch(_NUMBER + r"\s*(m|cm|ft)?", text)
    if not match:
        return None
    value = float(match[1].replace(",", "."))
    return {"cm": value / 100, "ft": value * 0.3048}.get(match[2], value)


def parse_weight(raw: str) -> float | None:
    """Masa w tonach z tagu OSM: "7.5", "7,5 t", "7500 kg", "10 st", "20000 lbs"."""
    text = raw.strip().lower()
    if text in _NO_VALUE:
        return None
    match = re.fullmatch(_NUMBER + r"\s*(t|kg|st|lbs)?", text)
    if not match:
        return None
    value = float(match[1].replace(",", "."))
    factor = {"kg": 0.001, "st": 0.90718, "lbs": 0.00045359}.get(match[2], 1.0)
    return round(value * factor, 3)


def restrictions_from_tags(tags: dict[str, str]) -> list[tuple[Kind, float | None, str]]:
    """Ograniczenia zapisane w tagach jednego obiektu OSM: (rodzaj, wartość, surowy tag)."""
    found: dict[Kind, tuple[Kind, float | None, str]] = {}
    for key, kind in LENGTH_TAGS.items():
        if key in tags and kind not in found and (value := parse_length(tags[key])):
            raw = f"{key}={tags[key]}"
            sign = key.removesuffix(":physical")
            if sign != key and sign in tags:
                # Pomiar i znak razem: ocena potrzebuje obu (znak dopuszcza, pomiar ostrzega).
                raw += f";{sign}={tags[sign]}"
            found[kind] = (kind, value, raw)
    for key, kind in WEIGHT_TAGS.items():
        if key in tags and kind not in found and (value := parse_weight(tags[key])):
            found[kind] = (kind, value, f"{key}={tags[key]}")
    hgv = tags.get("hgv")
    if hgv == "no":
        found[Kind.HGV_NO] = (Kind.HGV_NO, None, "hgv=no")
    elif hgv in {"destination", "delivery"}:
        found[Kind.HGV_DESTINATION] = (Kind.HGV_DESTINATION, None, f"hgv={hgv}")
    elif hgv in {"yes", "designated"} and tags.get("highway") in MINOR_HIGHWAYS:
        found[Kind.HGV_DESIGNATED] = (Kind.HGV_DESIGNATED, None, f"hgv={hgv}")
    conditional = [
        (Kind.CONDITIONAL, None, f"{key}={tags[key]}"[:255])
        for key in CONDITIONAL_TAGS
        if key in tags
    ]
    if tags.get("highway") in MINOR_HIGHWAYS:
        if "width" in tags and (value := parse_length(tags["width"])):
            found[Kind.ROAD_WIDTH] = (Kind.ROAD_WIDTH, value, f"width={tags['width']}")
        if tags.get("smoothness") in BAD_SMOOTHNESS:
            raw = f"smoothness={tags['smoothness']}"
            found[Kind.BAD_SURFACE] = (Kind.BAD_SURFACE, None, raw)
    return list(found.values()) + conditional


def for_ways(
    db: Session, way_ids: Iterable[int], cache: dict[int, list[Restriction]] | None = None
) -> dict[int, list[Restriction]]:
    """Ograniczenia dla podanych dróg OSM, pogrupowane po identyfikatorze drogi.

    ``cache`` – drogi pobrane wcześniej (także te bez ograniczeń); kolejne warianty tej samej
    trasy mają w większości wspólne drogi, więc z bazy pobierane są tylko nowe.
    """
    cache = {} if cache is None else cache
    ids = set(way_ids)
    missing = [i for i in ids if i not in cache]
    for start in range(0, len(missing), 1000):
        chunk = missing[start : start + 1000]
        for way_id in chunk:
            cache[way_id] = []
        query = select(Restriction).where(
            Restriction.osm_type == "way", Restriction.osm_id.in_(chunk)
        )
        for restriction in db.scalars(query):
            cache[restriction.osm_id].append(restriction)
    return {i: cache[i] for i in ids if cache[i]}


# Kawałki trasy do zapytań o otoczenie: prostokąt wokół całej długiej trasy obejmuje pół
# kraju, a pas wokół kolejnych ~10 km – tylko to, co faktycznie leży przy drodze.
QUERY_CHUNK_KM = 10.0
QUERY_BATCH = 40


def route_chunks(route: list[tuple[float, float]], max_km: float = QUERY_CHUNK_KM):
    """Kawałki linii trasy po ok. ``max_km`` (sąsiednie mają wspólny punkt)."""
    start, length = 0, 0.0
    for i in range(1, len(route)):
        length += distance_m(*route[i - 1], *route[i])
        if length >= max_km * 1000:
            yield route[start : i + 1]
            start, length = i, 0.0
    if start < len(route) - 1 or len(route) == 1:
        yield route[start:]


def nodes_near_route(
    db: Session,
    points: list[tuple[float, float]],
    kinds: Iterable[str],
    margin_m: float = 50.0,
) -> list[Restriction]:
    """Ograniczenia punktowe podanych rodzajów w pasie wokół trasy (dokładne dopasowanie robi
    analiza). Punkt ma prostokąt zerowy (``min_lat`` = ``lat``) – zapytanie trafia w indeks."""
    margin_lat, margin_lon = margin_m / 111_000, margin_m / 111_000 / 0.5
    boxes = []
    for chunk in route_chunks(points):
        lons, lats = [p[0] for p in chunk], [p[1] for p in chunk]
        boxes.append(
            and_(
                Restriction.min_lat.between(min(lats) - margin_lat, max(lats) + margin_lat),
                Restriction.min_lon.between(min(lons) - margin_lon, max(lons) + margin_lon),
            )
        )
    found: dict[int, Restriction] = {}
    kinds = list(kinds)
    for start in range(0, len(boxes), QUERY_BATCH):
        query = select(Restriction).where(
            Restriction.osm_type == "node",
            Restriction.kind.in_(kinds),
            or_(*boxes[start : start + QUERY_BATCH]),
        )
        for restriction in db.scalars(query):
            found[restriction.id] = restriction
    return list(found.values())


def distance_m(lon1: float, lat1: float, lon2: float, lat2: float) -> float:
    """Odległość w metrach (przybliżenie równoprostokątne – wystarczy na krótkie dystanse)."""
    x = math.radians(lon2 - lon1) * math.cos(math.radians((lat1 + lat2) / 2))
    y = math.radians(lat2 - lat1)
    return 6_371_000 * math.hypot(x, y)
