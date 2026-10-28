"""Import parkingów dla ciężarówek z pliku OSM (.osm.pbf) do bazy TruckMaps.

Parkingi z oznaczeniem dla ciężarówek (hgv=yes/designated, capacity:hgv) oraz MOP-y.
Zastępuje wcześniej zaimportowane parkingi ze źródła "osm". Uruchomienie z katalogu
głównego repozytorium (po migracjach bazy):

    .venv\\Scripts\\python data_pipeline\\import_parkings.py infra\\data\\valhalla\\*.osm.pbf
"""

import argparse
import os
import sys
import time
from pathlib import Path

import osmium
import shapely
from sqlalchemy import delete, insert

from truckmaps.core.config import load_env_file
from truckmaps.core.db import Database
from truckmaps.core.parkings import TruckParking, parking_kind

sys.path.insert(0, str(Path(__file__).parent))
from import_restrictions import file_date  # noqa: E402

SOURCE = "osm"


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
        db.execute(delete(TruckParking).where(TruckParking.source == SOURCE))
        for path in args.pbf:
            rows = list(read_parkings(path, file_date(path)))
            if rows:
                db.execute(insert(TruckParking), rows)
            kinds = {
                kind: sum(r["kind"] == kind for r in rows) for kind in {r["kind"] for r in rows}
            }
            print(f"{path.name}: {len(rows)} parkingów dla ciężarówek {kinds}")
        db.commit()
    print(f"Gotowe w {time.monotonic() - started:.0f} s")


def read_parkings(path: Path, source_date: str):
    objects = (
        osmium.FileProcessor(str(path))
        .with_areas()
        .with_filter(
            osmium.filter.TagFilter(
                ("amenity", "parking"), ("highway", "rest_area"), ("highway", "services")
            )
        )
    )
    for obj in objects:
        # Parking jako punkt albo obszar; drogi zamknięte pomijamy – wrócą jako obszary.
        if obj.is_node():
            lat, lon, osm_type, osm_id = obj.location.lat, obj.location.lon, "node", obj.id
        elif obj.is_area():
            rings = [[(n.lon, n.lat) for n in outer] for outer in obj.outer_rings()]
            polygons = [shapely.Polygon(ring) for ring in rings if len(ring) >= 4]
            if not polygons:
                continue
            centroid = shapely.MultiPolygon(polygons).centroid
            lat, lon = centroid.y, centroid.x
            osm_type = "way" if obj.from_way() else "relation"
            osm_id = obj.orig_id()
        else:
            continue
        tags = {tag.k: tag.v for tag in obj.tags}
        kind = parking_kind(tags)
        if kind is None:
            continue
        capacity = tags.get("capacity:hgv", "")
        yield {
            "osm_type": osm_type,
            "osm_id": osm_id,
            "kind": kind,
            "name": (tags.get("name") or None) and tags["name"][:200],
            "lat": lat,
            "lon": lon,
            "hgv_capacity": int(capacity) if capacity.isdigit() else None,
            "source": SOURCE,
            "source_date": source_date,
        }


if __name__ == "__main__":
    main()
