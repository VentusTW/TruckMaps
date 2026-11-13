"""Import punktów do ostrzeżeń w nawigacji z pliku OSM (.osm.pbf) do bazy TruckMaps.

Przejazdy kolejowe, fotoradary, sygnalizacja świetlna, odcinkowe pomiary prędkości
(relacje ``enforcement``) i zakazy wyprzedzania. Zastępuje wcześniej zaimportowane punkty
ze źródła "osm". Uruchomienie z katalogu głównego repozytorium (po migracjach bazy):

    .venv\\Scripts\\python data_pipeline\\import_road_points.py infra\\data\\valhalla\\*.osm.pbf
"""

import argparse
import os
import sys
import time
from pathlib import Path

import osmium
from sqlalchemy import delete, insert

from truckmaps.core.config import load_env_file
from truckmaps.core.db import Database
from truckmaps.core.polyline import encode_polyline6
from truckmaps.core.road_points import PointKind, RoadPoint, parse_speed

sys.path.insert(0, str(Path(__file__).parent))
from import_restrictions import file_date  # noqa: E402

SOURCE = "osm"
BATCH = 5000


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("pbf", nargs="+", type=Path, help="pliki .osm.pbf (np. kilka krajów)")
    args = parser.parse_args()

    load_env_file(Path.cwd() / ".env")
    url = os.environ.get("TRUCKMAPS_DATABASE_URL")
    if not url:
        sys.exit("Ustaw TRUCKMAPS_DATABASE_URL (w zmiennych środowiskowych albo w .env).")

    started = time.monotonic()
    with Database(url).session() as db:
        db.execute(delete(RoadPoint).where(RoadPoint.source == SOURCE))
        for path in args.pbf:
            counts: dict[str, int] = {}
            batch = []
            for row in read_points(path, file_date(path)):
                counts[row["kind"]] = counts.get(row["kind"], 0) + 1
                batch.append(row)
                if len(batch) >= BATCH:
                    db.execute(insert(RoadPoint), batch)
                    batch = []
            if batch:
                db.execute(insert(RoadPoint), batch)
            print(f"{path.name}: {counts}")
        db.commit()
    print(f"Gotowe w {time.monotonic() - started:.0f} s")


def node_kind(tags: dict[str, str]) -> PointKind | None:
    if tags.get("railway") == "level_crossing":
        return PointKind.LEVEL_CROSSING
    if tags.get("highway") == "speed_camera":
        return PointKind.SPEED_CAMERA
    if tags.get("highway") == "traffic_signals":
        return PointKind.TRAFFIC_SIGNALS
    return None


def no_overtaking(tags: dict[str, str]) -> bool:
    """Zakaz wyprzedzania dla ciężarówek – osobny dla hgv albo dla wszystkich pojazdów."""
    return "highway" in tags and (
        tags.get("overtaking:hgv") == "no" or tags.get("overtaking") == "no"
    )


def average_speed(tags: dict[str, str]) -> bool:
    return tags.get("type") == "enforcement" and tags.get("enforcement") == "average_speed"


def _row(kind: str, osm_type: str, osm_id: int, points, source_date: str, **extra) -> dict:
    lons, lats = [p[0] for p in points], [p[1] for p in points]
    return {
        "osm_type": osm_type,
        "osm_id": osm_id,
        "kind": kind,
        "lat": lats[0],
        "lon": lons[0],
        "end_lat": None,
        "end_lon": None,
        "line": None,
        "value": None,
        "min_lat": min(lats),
        "min_lon": min(lons),
        "max_lat": max(lats),
        "max_lon": max(lons),
        "source": SOURCE,
        "source_date": source_date,
    } | extra


# Klucze tagów punktów (węzły) i zakazów wyprzedzania (drogi).
POINT_KEYS = ("railway", "highway", "overtaking", "overtaking:hgv")


def read_points(path: Path, source_date: str):
    # Pierwsze przejście: relacje pomiaru odcinkowego – potrzebne węzły początku i końca.
    sections: dict[int, dict] = {}
    for rel in osmium.FileProcessor(str(path), osmium.osm.RELATION):
        tags = {tag.k: tag.v for tag in rel.tags}
        if not average_speed(tags):
            continue
        members = {m.role: m.ref for m in rel.members if m.type == "n" and m.role in ("from", "to")}
        if len(members) == 2:
            sections[rel.id] = {**members, "speed": parse_speed(tags.get("maxspeed"))}
    wanted = {ref for s in sections.values() for ref in (s["from"], s["to"])}
    located: dict[int, tuple[float, float]] = {}
    # Węzły początku i końca odcinków – osobno i tylko po identyfikatorach (zwykle bez tagów).
    if wanted:
        nodes = osmium.FileProcessor(str(path), osmium.osm.NODE).with_filter(
            osmium.filter.IdFilter(wanted)
        )
        for node in nodes:
            located[node.id] = (node.location.lon, node.location.lat)

    # Filtr po kluczach w bibliotece: do Pythona trafiają tylko obiekty z potrzebnymi tagami.
    # Bez niego przy pliku kilku krajów (ok. miliarda węzłów) proces padał (naruszenie pamięci).
    objects = (
        osmium.FileProcessor(str(path), osmium.osm.NODE | osmium.osm.WAY)
        .with_locations()
        .with_filter(osmium.filter.KeyFilter(*POINT_KEYS))
    )
    for obj in objects:
        if obj.is_node():
            point = (obj.location.lon, obj.location.lat)
            tags = {tag.k: tag.v for tag in obj.tags}
            kind = node_kind(tags)
            if kind is not None:
                speed = (
                    parse_speed(tags.get("maxspeed")) if kind == PointKind.SPEED_CAMERA else None
                )
                yield _row(kind, "node", obj.id, [point], source_date, value=speed)
            continue
        tags = {tag.k: tag.v for tag in obj.tags}
        if not no_overtaking(tags):
            continue
        points = [(n.lon, n.lat) for n in obj.nodes if n.location.valid()]
        if len(points) >= 2:
            line = encode_polyline6(points)
            yield _row(PointKind.NO_OVERTAKING, "way", obj.id, points, source_date, line=line)

    for rel_id, section in sections.items():
        start, end = located.get(section["from"]), located.get(section["to"])
        if start and end:
            yield _row(
                PointKind.AVERAGE_SPEED, "relation", rel_id, [start, end], source_date,
                end_lon=end[0], end_lat=end[1], value=section["speed"],
            )  # fmt: skip


if __name__ == "__main__":
    main()
