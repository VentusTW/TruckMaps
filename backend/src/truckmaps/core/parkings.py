"""Parkingi, na których stanie ciężarówka (z OSM): parkingi dla ciężarówek i MOP-y."""

from sqlalchemy import BigInteger, Float, Index, Integer, String, select
from sqlalchemy.orm import Mapped, Session, mapped_column

from truckmaps.core.db import Base
from truckmaps.core.i18n import t
from truckmaps.core.restrictions import distance_m

SAME_PLACE_M = 100.0

PARKING_KINDS = ("truck_parking", "rest_area", "services")


def kind_label(kind: str) -> str:
    """Nazwa rodzaju parkingu w języku zapytania (tekst ``parking.<rodzaj>``)."""
    return t(f"parking.{kind}") if kind in PARKING_KINDS else kind


class TruckParking(Base):
    __tablename__ = "truck_parkings"
    __table_args__ = (Index("ix_truck_parkings_lat_lon", "lat", "lon"),)

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    osm_type: Mapped[str] = mapped_column(String(8))
    osm_id: Mapped[int] = mapped_column(BigInteger)
    kind: Mapped[str] = mapped_column(String(20))
    name: Mapped[str | None] = mapped_column(String(200))
    lat: Mapped[float] = mapped_column(Float)
    lon: Mapped[float] = mapped_column(Float)
    hgv_capacity: Mapped[int | None] = mapped_column(Integer)
    source: Mapped[str] = mapped_column(String(30))
    source_date: Mapped[str] = mapped_column(String(20))


def parking_kind(tags: dict[str, str]) -> str | None:
    """Rodzaj parkingu dla ciężarówek z tagów OSM; ``None`` – zwykły parking albo nie parking."""
    closed = (
        tags.get("hgv") == "no"
        or tags.get("motor_vehicle") == "no"
        or tags.get("access") in ("no", "private")
        # "Miejsca Obsługi Rowerzystów" też bywają oznaczone jako highway=rest_area.
        or "rower" in tags.get("name", "").lower()
        or tags.get("bicycle") == "designated"
    )
    if closed:
        return None
    highway = tags.get("highway")
    if highway in ("rest_area", "services"):
        return highway
    if tags.get("amenity") != "parking":
        return None
    capacity = tags.get("capacity:hgv", "")
    if tags.get("hgv") in ("yes", "designated") or (capacity.isdigit() and int(capacity) > 0):
        return "truck_parking"
    return None


def nearest(
    db: Session, lat: float, lon: float, radius_m: float = 5000.0, limit: int = 3
) -> list[tuple[TruckParking, float]]:
    """Najbliższe parkingi dla ciężarówek: (parking, odległość w metrach), od najbliższego."""
    margin = radius_m / 111_000
    query = select(TruckParking).where(
        TruckParking.lat.between(lat - margin, lat + margin),
        TruckParking.lon.between(lon - 2 * margin, lon + 2 * margin),
    )
    found = [(p, distance_m(lon, lat, p.lon, p.lat)) for p in db.scalars(query)]
    result: list[tuple[TruckParking, float]] = []
    for parking, distance in sorted(found, key=lambda item: item[1]):
        if distance > radius_m:
            break
        # Ten sam parking bywa w OSM i jako punkt, i jako obszar.
        if any(
            distance_m(parking.lon, parking.lat, p.lon, p.lat) < SAME_PLACE_M for p, _ in result
        ):
            continue
        result.append((parking, distance))
        if len(result) == limit:
            break
    return result
