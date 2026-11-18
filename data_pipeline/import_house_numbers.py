"""Import numerów domów (pomoc przy dojeździe do celu) do bazy TruckMaps.

Źródła:
- ``osm`` – obiekty z ``addr:housenumber`` z plików .osm.pbf (punkty i budynki – środek
  obrysu), te same pliki co dla tras:
      .venv\\Scripts\\python data_pipeline\\import_house_numbers.py osm ^
          infra\\data\\valhalla\\*.osm.pbf
- ``prg`` – punkty adresowe z państwowego rejestru granic (GUGiK, PRG, dane otwarte) w GML
  (schemat PRGAD: miejscowości, ulice i punkty jako osobne obiekty z odnośnikami ``xlink``),
  współrzędne w układzie PL-1992 (EPSG:2180). Plik całej Polski (ok. 0,8 GB, w środku GML
  województw) – https://opendata.geoportal.gov.pl/prg/adresy/PRG-punkty_adresowe.zip –
  pobiera się osobno (skrypt niczego nie pobiera); czytany wprost z zipa:
      .venv\\Scripts\\python data_pipeline\\import_house_numbers.py prg ^
          infra\\data\\prg\\PRG-punkty_adresowe.zip

Każdy import zastępuje wcześniejsze rekordy tego samego źródła. W GML kolejność osi według
EPSG:2180 to (północ, wschód); ``--xy`` – gdy plik ma (wschód, północ).
"""

import argparse
import os
import sys
import time
import xml.etree.ElementTree as ET
import zipfile
from datetime import UTC, datetime
from pathlib import Path

from sqlalchemy import delete, insert

from truckmaps.core.config import load_env_file
from truckmaps.core.db import Database
from truckmaps.core.house_numbers import HouseNumber, puwg92_to_wgs84

BATCH = 50_000
# Obiekty GML PRG (schemat PRGAD i starsze) i ich pola.
PRG_POINT = {"PRG_PunktAdresowy", "AD_PunktAdresowy", "PunktAdresowy"}
PRG_STREET_OBJECT = {"AD_UlicaPlac", "AD_Ulica"}
PRG_PLACE_OBJECT = {"AD_Miejscowosc"}
PRG_NUMBER = ("numerPorzadkowy", "numerNaBudynku", "numer")
PRG_STREET = ("ulica", "ulicaPlac", "nazwaUlicy")
PRG_PLACE = ("miejscowosc", "nazwaMiejscowosci")
GML_ID = "{http://www.opengis.net/gml/3.2}id"
XLINK = "{http://www.w3.org/1999/xlink}href"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("source", choices=["osm", "prg"])
    parser.add_argument("files", nargs="+", type=Path)
    parser.add_argument("--xy", action="store_true", help="GML PRG: współrzędne (wschód, północ)")
    args = parser.parse_args()

    load_env_file(Path.cwd() / ".env")
    url = os.environ.get("TRUCKMAPS_DATABASE_URL")
    if not url:
        sys.exit("Ustaw TRUCKMAPS_DATABASE_URL (w zmiennych środowiskowych albo w .env).")

    started = time.monotonic()
    with Database(url).session() as db:
        db.execute(delete(HouseNumber).where(HouseNumber.source == args.source))
        for path in args.files:
            if args.source == "osm":
                sys.path.insert(0, str(Path(__file__).parent))
                from import_restrictions import file_date  # osmium – tylko dla źródła OSM

                rows = read_osm(path, file_date(path))
            else:
                rows = read_prg(path, _mtime(path), xy=args.xy)
            count = 0
            for batch in _batches(rows):
                db.execute(insert(HouseNumber), batch)
                count += len(batch)
                # Zapis co paczkę: duży import (cała Polska) nie trzyma wszystkiego w transakcji.
                db.commit()
            print(f"{path.name}: {count} numerów domów", flush=True)
        db.commit()
    print(f"Gotowe w {time.monotonic() - started:.0f} s")


def _mtime(path: Path) -> str:
    return datetime.fromtimestamp(path.stat().st_mtime, UTC).date().isoformat()


def _batches(rows):
    batch = []
    for row in rows:
        batch.append(row)
        if len(batch) >= BATCH:
            yield batch
            batch = []
    if batch:
        yield batch


def _row(lat, lon, number, street, source, source_date) -> dict:
    return {
        "lat": lat,
        "lon": lon,
        "number": number.strip()[:20],
        "street": (street or "").strip()[:200] or None,
        "source": source,
        "source_date": source_date,
    }


def read_osm(path: Path, source_date: str):
    # Biblioteki OSM tylko tutaj – czytnik PRG (i testy) działa bez nich.
    import osmium
    import shapely

    objects = (
        osmium.FileProcessor(str(path))
        .with_areas()
        .with_filter(osmium.filter.KeyFilter("addr:housenumber"))
    )
    for obj in objects:
        tags = obj.tags
        number = tags.get("addr:housenumber")
        if not number:
            continue
        street = tags.get("addr:street") or tags.get("addr:place")
        if obj.is_node():
            yield _row(obj.location.lat, obj.location.lon, number, street, "osm", source_date)
        elif obj.is_area():
            rings = [[(n.lon, n.lat) for n in outer] for outer in obj.outer_rings()]
            polygons = [shapely.Polygon(ring) for ring in rings if len(ring) >= 4]
            if polygons:
                centroid = shapely.MultiPolygon(polygons).centroid
                yield _row(centroid.y, centroid.x, number, street, "osm", source_date)


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _first_text(element, names) -> str | None:
    for child in element.iter():
        if _local(child.tag) in names and (child.text or "").strip():
            return child.text.strip()
    return None


def _ref(element, names) -> str | None:
    """Odnośnik ``xlink:href`` (bez ``#``) z pierwszego pola o tej nazwie."""
    for child in element:
        if _local(child.tag) in names and child.get(XLINK):
            return child.get(XLINK).lstrip("#")
    return None


def read_prg(path: Path, source_date: str, xy: bool = False):
    """Punkty adresowe z GML PRG – plik .gml albo .zip z plikami .gml (bez rozpakowywania)."""
    if path.suffix.lower() != ".zip":
        with path.open("rb") as stream:
            yield from _read_prg_stream(stream, source_date, xy)
        return
    with zipfile.ZipFile(path) as archive:
        for name in sorted(n for n in archive.namelist() if n.lower().endswith(".gml")):
            print(f"  {name}", flush=True)
            with archive.open(name) as stream:
                yield from _read_prg_stream(stream, source_date, xy)


def _read_prg_stream(stream, source_date: str, xy: bool):
    """Jeden plik GML: strumieniowo (województwo to do 1,6 GB), odnośniki rozwiązywane na końcu."""
    places: dict[str, str] = {}
    streets: dict[str, str] = {}
    street_of_point: dict[str, str] = {}
    points: list[tuple] = []
    root = None
    for event, element in ET.iterparse(stream, events=("start", "end")):
        if root is None:
            root = element
        if event == "start":
            continue
        kind = _local(element.tag)
        if kind in PRG_PLACE_OBJECT:
            if name := _first_text(element, {"nazwa"}):
                places[element.get(GML_ID, "")] = name
        elif kind in PRG_STREET_OBJECT:
            street_id = element.get(GML_ID, "")
            if name := _first_text(element, {"nazwaPelna", "nazwa"}):
                streets[street_id] = name
            for child in element:
                if _local(child.tag) == "adres2" and child.get(XLINK):
                    street_of_point[child.get(XLINK).lstrip("#")] = street_id
        elif kind in PRG_POINT:
            number = _first_text(element, PRG_NUMBER)
            position = _first_text(element, {"pos"})
            if number and position:
                first, second = (float(v) for v in position.split()[:2])
                east, north = (first, second) if xy else (second, first)
                points.append((
                    element.get(GML_ID, ""), east, north, number,
                    _ref(element, PRG_STREET), _ref(element, PRG_PLACE),
                    # starszy schemat: nazwy wprost w punkcie
                    None if _ref(element, PRG_STREET) else _first_text(element, PRG_STREET),
                    None if _ref(element, PRG_PLACE) else _first_text(element, PRG_PLACE),
                ))  # fmt: skip
        else:
            continue
        element.clear()
        root.clear()  # bez tego drzewo trzyma puste elementy i pamięć rośnie
    for point_id, east, north, number, street_ref, place_ref, street_text, place_text in points:
        street = (
            streets.get(street_ref or street_of_point.get(point_id, ""))
            or street_text
            or places.get(place_ref or "")
            or place_text
        )
        lat, lon = puwg92_to_wgs84(east, north)
        yield _row(lat, lon, number, street, "prg", source_date)


if __name__ == "__main__":
    main()
