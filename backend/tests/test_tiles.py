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
