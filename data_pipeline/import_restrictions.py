"""Import ograniczeń dla ciężarówek z pliku OSM (.osm.pbf) do bazy TruckMaps.

Zastępuje wszystkie wcześniej zaimportowane ograniczenia ze źródła "osm".
Uruchomienie z katalogu głównego repozytorium (po migracjach bazy):

    .venv\\Scripts\\python data_pipeline\\import_restrictions.py infra\\data\\valhalla\\*.osm.pbf
"""

import argparse
import math
import os
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

import numpy as np
import osmium
import shapely
from sqlalchemy import delete, insert

from truckmaps.core.config import load_env_file
from truckmaps.core.db import Database
from truckmaps.core.restrictions import (
    MINOR_HIGHWAYS,
    RESTRICTION_KEYS,
    Kind,
    Restriction,
    restrictions_from_tags,
)

SOURCE = "osm"
BATCH = 5000
# Strefa przemysłowa wokół drogi lokalnej: promień i minimalny udział terenu przemysłowego.
CONTEXT_RADIUS_M = 100.0
MIN_INDUSTRIAL_SHARE = 0.35


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("pbf", nargs="+", type=Path, help="pliki .osm.pbf (np. kilka krajów)")
    args = parser.parse_args()

    load_env_file(Path.cwd() / ".env")
    url = os.environ.get("TRUCKMAPS_DATABASE_URL")
    if not url:
        sys.exit("Ustaw TRUCKMAPS_DATABASE_URL (w zmiennych środowiskowych albo w .env).")
    database = Database(url)

    started = time.monotonic()
    with database.session() as db:
        db.execute(delete(Restriction).where(Restriction.source == SOURCE))
        total = 0
        for path in args.pbf:
            source_date = file_date(path)
            batch = []
            for row in read_restrictions(path, source_date):
                batch.append(row)
                if len(batch) >= BATCH:
                    db.execute(insert(Restriction), batch)
                    total += len(batch)
                    batch.clear()
            if batch:
                db.execute(insert(Restriction), batch)
                total += len(batch)
            print(f"{path.name}: dane z {source_date}, łącznie {total} ograniczeń")
            industrial = list(read_industrial_roads(path, source_date))
            for start in range(0, len(industrial), BATCH):
                db.execute(insert(Restriction), industrial[start : start + BATCH])
            print(f"{path.name}: {len(industrial)} dróg lokalnych w strefach przemysłowych")
        db.commit()
    print(f"Gotowe w {time.monotonic() - started:.0f} s")


def read_restrictions(path: Path, source_date: str):
    objects = osmium.FileProcessor(str(path), osmium.osm.NODE | osmium.osm.WAY).with_filter(
        osmium.filter.KeyFilter(*RESTRICTION_KEYS)
    )
    for obj in objects:
        tags = {tag.k: tag.v for tag in obj.tags}
        is_node = obj.is_node()
        for kind, value, raw in restrictions_from_tags(tags):
            yield {
                "osm_type": "node" if is_node else "way",
                "osm_id": obj.id,
                "kind": kind.value,
                "value": value,
                "raw": raw[:100],
                "lat": obj.location.lat if is_node else None,
                "lon": obj.location.lon if is_node else None,
                "source": SOURCE,
                "source_date": source_date,
            }


def read_industrial_roads(path: Path, source_date: str):
    """Drogi lokalne (np. "osiedlowe") w strefach przemysłowych.

    W strefach przemysłowych takie drogi są zwykle szerokie i jeżdżą nimi ciężarówki,
    choć w OSM bywają oznaczone tak samo jak wąskie uliczki na osiedlach. Droga zwykle
    biegnie *pomiędzy* obszarami zagospodarowania, więc liczy się otoczenie: udział terenu
    przemysłowego i mieszkaniowego w promieniu ~100 m od środka drogi.
    """
    industrial, residential = _landuse_trees(path)
    ids, lons, lats = _minor_road_midpoints(path)
    if not ids:
        return
    lons, lats = np.array(lons), np.array(lats)

    # Kandydaci: drogi, przy których w ogóle jest jakiś teren przemysłowy.
    near = industrial.query(
        shapely.points(lons, lats), predicate="dwithin", distance=CONTEXT_RADIUS_M / 111_195
    )
    candidates = np.unique(near[0])
    if not len(candidates):
        return

    # Udział terenu: ile z punktów próbnych wokół środka drogi leży w danym obszarze.
    offsets = _sample_offsets(CONTEXT_RADIUS_M)
    scale = np.cos(np.radians(lats[candidates]))
    sample_lons = (lons[candidates, None] + offsets[None, :, 0] / scale[:, None]).ravel()
    sample_lats = (lats[candidates, None] + offsets[None, :, 1]).ravel()
    samples = shapely.points(sample_lons, sample_lats)
    per_road = len(offsets)

    def share(tree: shapely.STRtree) -> np.ndarray:
        hits = np.zeros(len(samples), dtype=bool)
        hits[np.unique(tree.query(samples, predicate="intersects")[0])] = True
        return hits.reshape(len(candidates), per_road).mean(axis=1)

    industrial_share, residential_share = share(industrial), share(residential)
    chosen = (industrial_share >= MIN_INDUSTRIAL_SHARE) & (industrial_share > residential_share)
    for index, part in zip(candidates[chosen], industrial_share[chosen], strict=True):
        yield {
            "osm_type": "way",
            "osm_id": ids[index],
            "kind": Kind.INDUSTRIAL_AREA.value,
            "value": round(float(part), 2),
            "raw": "landuse=industrial (otoczenie)",
            "lat": None,
            "lon": None,
            "source": SOURCE,
            "source_date": source_date,
        }


def _landuse_trees(path: Path) -> tuple[shapely.STRtree, shapely.STRtree]:
    """Obszary przemysłowe i mieszkaniowe jako indeksy przestrzenne."""
    rings: dict[str, list] = {"industrial": [], "residential": []}
    areas = (
        osmium.FileProcessor(str(path))
        .with_areas()
        .with_filter(osmium.filter.TagFilter(("landuse", "industrial"), ("landuse", "residential")))
    )
    for obj in areas:
        if not obj.is_area():
            continue
        # Współrzędne kopiujemy od razu – obiekt pyosmium jest ważny tylko w tej iteracji.
        landuse = obj.tags.get("landuse")
        for outer in obj.outer_rings():
            shell = [(n.lon, n.lat) for n in outer]
            holes = [[(n.lon, n.lat) for n in inner] for inner in obj.inner_rings(outer)]
            rings[landuse].append((shell, holes))
    trees = []
    for landuse in ("industrial", "residential"):
        polygons = [shapely.Polygon(shell, holes) for shell, holes in rings[landuse]]
        trees.append(shapely.STRtree([p for p in polygons if p.is_valid and not p.is_empty]))
    return trees[0], trees[1]


def _minor_road_midpoints(path: Path) -> tuple[list[int], list[float], list[float]]:
    ids, lons, lats = [], [], []
    ways = (
        # Węzły są potrzebne do położenia dróg (cache lokalizacji), choć ich nie zwracamy.
        osmium.FileProcessor(str(path), osmium.osm.NODE | osmium.osm.WAY)
        .with_locations()
        .with_filter(osmium.filter.TagFilter(*(("highway", value) for value in MINOR_HIGHWAYS)))
    )
    for way in ways:
        if not way.is_way():
            continue
        nodes = way.nodes
        middle = nodes[len(nodes) // 2]
        if middle.location.valid():
            ids.append(way.id)
            lons.append(middle.location.lon)
            lats.append(middle.location.lat)
    return ids, lons, lats


def _sample_offsets(radius_m: float) -> np.ndarray:
    """Środek, 6 punktów w połowie promienia i 6 na promieniu (w stopniach szerokości)."""
    points = [(0.0, 0.0)]
    for fraction, start in ((0.5, 0.0), (0.95, 30.0)):
        for k in range(6):
            angle = math.radians(start + k * 60)
            points.append((math.cos(angle) * fraction, math.sin(angle) * fraction))
    return np.array(points) * radius_m / 111_195


def file_date(path: Path) -> str:
    """Data stanu danych: z nagłówka pliku OSM, a gdy jej brak – data modyfikacji pliku."""
    header = osmium.io.Reader(str(path), osmium.osm.osm_entity_bits.NOTHING).header()
    stamp = header.get("osmosis_replication_timestamp")
    if stamp:
        return stamp[:10]
    return datetime.fromtimestamp(path.stat().st_mtime, UTC).date().isoformat()


if __name__ == "__main__":
    main()
