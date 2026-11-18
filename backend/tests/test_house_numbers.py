import importlib.util
from pathlib import Path

import pytest
from sqlalchemy.pool import StaticPool

from truckmaps.core.db import Base, Database
from truckmaps.core.house_numbers import (
    HouseNumber,
    near_route_ends,
    puwg92_to_wgs84,
    wgs84_to_puwg92,
)

# Prosta trasa wzdłuż równoleżnika 50°: ok. 7,2 km (0,1° długości).
ROUTE = [(20.0 + i * 0.001, 50.0) for i in range(101)]


def house(lon: float, lat: float, number: str, street: str = "Długa") -> HouseNumber:
    return HouseNumber(
        lat=lat, lon=lon, number=number, street=street, source="osm", source_date="2026-11-01"
    )


def test_house_numbers_only_near_start_and_destination():
    database = Database(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(database.engine)
    with database.session() as db:
        db.add_all(
            [
                house(20.0005, 50.0003, "1"),  # przy starcie, ok. 33 m od drogi
                house(20.0995, 50.0002, "12A"),  # przy celu
                house(20.0995, 50.0020, "99"),  # przy celu, ale 220 m od drogi
                house(20.0500, 50.0002, "7"),  # w połowie trasy – bez numeru
            ]
        )
        db.commit()
        found = near_route_ends(db, ROUTE)

    assert [(h.number, h.end) for h in found] == [("12A", "end"), ("1", "start")]
    assert found[0].street == "Długa"


def test_puwg92_round_trip_and_known_point():
    # Pałac Kultury i Nauki w PL-1992 (wschód ok. 637 000, północ ok. 487 000).
    east, north = wgs84_to_puwg92(52.2318, 21.0060)
    assert (round(east, -3), round(north, -3)) == (637_000, 487_000)
    lat, lon = puwg92_to_wgs84(east, north)
    assert (lat, lon) == (pytest.approx(52.2318, abs=1e-7), pytest.approx(21.006, abs=1e-7))


def test_prg_gml_reader(tmp_path: Path):
    spec = importlib.util.spec_from_file_location(
        "import_house_numbers",
        Path(__file__).parents[2] / "data_pipeline" / "import_house_numbers.py",
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    east, north = wgs84_to_puwg92(50.0121, 20.9858)
    gml = tmp_path / "prg.gml"
    gml.write_text(
        f"""<?xml version="1.0" encoding="UTF-8"?>
<gml:FeatureCollection xmlns:gml="http://www.opengis.net/gml/3.2"
    xmlns:prg-ad="urn:gugik:specyfikacje:gmlas:panstwowyRejestrGranicAdresy:2.0">
  <gml:featureMember>
    <prg-ad:PRG_PunktAdresowy gml:id="p1">
      <prg-ad:miejscowosc>Tarnów</prg-ad:miejscowosc>
      <prg-ad:ulica>Krakowska</prg-ad:ulica>
      <prg-ad:numerPorzadkowy>11b</prg-ad:numerPorzadkowy>
      <prg-ad:pozycja><gml:Point srsName="EPSG:2180">
        <gml:pos>{north} {east}</gml:pos>
      </gml:Point></prg-ad:pozycja>
    </prg-ad:PRG_PunktAdresowy>
  </gml:featureMember>
</gml:FeatureCollection>
""",
        encoding="utf-8",
    )
    rows = list(module.read_prg(gml, "2026-11-18"))
    assert [(r["number"], r["street"], r["source"]) for r in rows] == [("11b", "Krakowska", "prg")]
    assert (rows[0]["lat"], rows[0]["lon"]) == (
        pytest.approx(50.0121, abs=1e-6),
        pytest.approx(20.9858, abs=1e-6),
    )


def test_prg_gml_reader_resolves_streets_and_places_by_links(tmp_path: Path):
    """Schemat PRGAD: ulica wskazuje swoje punkty (``adres2``), punkt – miejscowość."""
    spec = importlib.util.spec_from_file_location(
        "import_house_numbers",
        Path(__file__).parents[2] / "data_pipeline" / "import_house_numbers.py",
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    east, north = wgs84_to_puwg92(51.68, 14.98)

    def point(gml_id: str, number: str) -> str:
        return f"""<gml:featureMember><prgad:AD_PunktAdresowy gml:id="{gml_id}">
      <prgad:numerPorzadkowy>{number}</prgad:numerPorzadkowy>
      <prgad:georeferencja><gml:Point><gml:pos>{north} {east}</gml:pos></gml:Point>
      </prgad:georeferencja>
      <prgad:miejscowosc xlink:href="#m1"/>
    </prgad:AD_PunktAdresowy></gml:featureMember>"""

    gml = tmp_path / "prgad.gml"
    gml.write_text(
        f"""<?xml version="1.0" encoding="UTF-8"?>
<gml:FeatureCollection xmlns:gml="http://www.opengis.net/gml/3.2"
    xmlns:prgad="https://geoportal.gov.pl/schemas/prgad/1.0"
    xmlns:xlink="http://www.w3.org/1999/xlink">
  <gml:featureMember><prgad:AD_Miejscowosc gml:id="m1">
    <prgad:nazwa>Pietrzyków</prgad:nazwa></prgad:AD_Miejscowosc></gml:featureMember>
  <gml:featureMember><prgad:AD_UlicaPlac gml:id="u1">
    <prgad:nazwaPelna>Plac Kasztanowy</prgad:nazwaPelna>
    <prgad:adres2 xlink:href="#p2"/></prgad:AD_UlicaPlac></gml:featureMember>
  {point("p1", "43")}
  {point("p2", "5a")}
</gml:FeatureCollection>
""",
        encoding="utf-8",
    )
    rows = list(module.read_prg(gml, "2026-11-18"))
    assert [(r["number"], r["street"]) for r in rows] == [
        ("43", "Pietrzyków"),
        ("5a", "Plac Kasztanowy"),
    ]
