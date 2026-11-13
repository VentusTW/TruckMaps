from fastapi.testclient import TestClient

from truckmaps.core.app import create_app
from truckmaps.core.config import Settings


def test_vector_tiles_listed_and_served_with_ranges(tmp_path):
    (tmp_path / "poland.pmtiles").write_bytes(b"PMTiles" + bytes(1000))
    (tmp_path / "notes.txt").write_text("nie kafelki")
    client = TestClient(create_app(Settings(tiles_dir=tmp_path), modules=[]))

    assert client.get("/api/tiles").json() == [
        {"name": "poland", "url": "/api/tiles/poland.pmtiles", "size_mb": 0.0}
    ]
    part = client.get("/api/tiles/poland.pmtiles", headers={"Range": "bytes=0-6"})
    assert part.status_code == 206
    assert part.content == b"PMTiles"
    assert client.get("/api/tiles/brak.pmtiles").status_code == 404
    assert client.get("/api/tiles/..%2Fnotes.pmtiles").status_code == 404


def test_no_tiles_directory_means_raster_map(tmp_path):
    client = TestClient(create_app(Settings(tiles_dir=tmp_path / "brak"), modules=[]))

    assert client.get("/api/tiles").json() == []


def test_restriction_signs_in_visible_area_only(database):
    from truckmaps.core.restrictions import Restriction
    from truckmaps.core.signs import signs_in

    def row(kind, value, lat, lon):
        return Restriction(
            osm_type="way", osm_id=1, kind=kind, value=value, raw=f"{kind}={value}", lat=lat,
            lon=lon, min_lat=lat, min_lon=lon, max_lat=lat, max_lon=lon, source="osm",
            source_date="2026-11-01",
        )  # fmt: skip

    with database.session() as db:
        db.add_all([
            row("weight", 12, 50.70, 23.00),
            row("weight", 12, 50.70, 23.00),  # ten sam znak z dwóch dróg – jeden na mapie
            row("height", 3.5, 50.72, 23.10),
            row("weight", 615, 50.71, 23.05),  # błąd w danych
            row("hgv_no", None, 50.71, 23.02),  # zakaz bez liczby – nie jest znakiem z wartością
            row("weight", 8, 52.0, 21.0),  # poza obszarem
        ])  # fmt: skip
        db.commit()

        found = signs_in(db, 50.6, 22.9, 50.8, 23.2)
        assert sorted((s.kind, s.value) for s in found) == [("height", 3.5), ("weight", 12.0)]
        assert signs_in(db, 49.0, 14.0, 55.0, 24.0) == []  # cała Polska – za szeroko
