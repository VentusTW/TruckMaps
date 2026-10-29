from pathlib import Path

import pobieraj
import pytest
from pobieraj import Remote, find_root, format_duration, latest_photon_release, parse_headers

REDIRECTED = """HTTP/1.1 307 Temporary Redirect
Location: https://download.geofabrik.de/europe/germany-251028.osm.pbf
Content-Length: 0

HTTP/1.1 200 OK
Content-Length: 4870645940
Last-Modified: Wed, 28 Oct 2026 02:16:18 GMT
Accept-Ranges: bytes
"""


def test_headers_of_last_response_after_redirect():
    assert parse_headers(REDIRECTED) == Remote(
        size=4870645940, last_modified="Wed, 28 Oct 2026 02:16:18 GMT", ranges=True
    )


def test_headers_without_ranges():
    remote = parse_headers("HTTP/2 200\ncontent-length: 10\n")
    assert (remote.size, remote.last_modified, remote.ranges) == (10, "", False)


@pytest.mark.parametrize(
    ("start", "size", "pieces", "expected"),
    [
        (0, 100, 4, [(0, 24), (25, 49), (50, 74), (75, 99)]),
        (40, 100, 3, [(40, 59), (60, 79), (80, 99)]),
        (0, 10, 4, [(0, 2), (3, 5), (6, 8), (9, 9)]),
        (98, 100, 8, [(98, 98), (99, 99)]),
    ],
)
def test_split_ranges_cover_rest_of_file_without_gaps(start, size, pieces, expected):
    ranges = pobieraj.split_ranges(start, size, pieces)
    assert ranges == expected
    assert sum(b - a + 1 for a, b in ranges) == size - start


def test_latest_photon_release_ignores_md5_and_other_dumps():
    listing = """
      <a href="photon-dump-europe-release-261018.jsonl.zst">
      <a href="photon-dump-europe-release-261025.jsonl.zst.md5">
      <a href="photon-dump-europe-release-261011.jsonl.zst">
      <a href="photon-dump-europe-master-261030.jsonl.zst">
    """
    assert latest_photon_release(listing) == "261018"


def test_format_duration():
    assert (format_duration(59), format_duration(600), format_duration(7380)) == (
        "0 min",
        "10 min",
        "2 h 03 min",
    )


def test_find_root_walks_up_to_project(tmp_path: Path):
    (tmp_path / "infra").mkdir()
    (tmp_path / "infra" / "docker-compose.yml").touch()
    nested = tmp_path / "dist" / "bin"
    nested.mkdir(parents=True)
    assert find_root(nested) == tmp_path


def test_fetch_skips_unchanged_file_and_records_new_one(tmp_path: Path, monkeypatch):
    target = tmp_path / "infra" / "data" / "osm" / "slovakia-latest.osm.pbf"
    target.parent.mkdir(parents=True)
    target.write_bytes(b"x" * 5)
    remote = Remote(size=5, last_modified="Wed, 28 Oct 2026", ranges=True)
    monkeypatch.setattr(pobieraj, "remote_info", lambda url: remote)
    monkeypatch.setattr(pobieraj, "remote_md5", lambda url: None)
    calls = []
    monkeypatch.setattr(pobieraj, "download", lambda *args: calls.append(args))

    downloader = pobieraj.Downloader(tmp_path, connections=8)
    # Plik pobrany wcześniej innym sposobem: sprawdzony i dopisany do pobrane.json.
    assert downloader.fetch("https://x/slovakia-latest.osm.pbf", target) is True
    entry = downloader.manifest["infra/data/osm/slovakia-latest.osm.pbf"]
    assert (entry["size"], entry["check"]) == (5, "rozmiar")

    # Ten sam plik na serwerze – bez pobierania.
    assert downloader.fetch("https://x/slovakia-latest.osm.pbf", target) is False

    # Nowsza wersja na serwerze – stary plik usunięty, pobieranie od nowa.
    monkeypatch.setattr(
        pobieraj, "remote_info", lambda url: Remote(5, "Thu, 29 Oct 2026", ranges=True)
    )
    with pytest.raises(RuntimeError, match="Niepełny"):
        downloader.fetch("https://x/slovakia-latest.osm.pbf", target)
    assert len(calls) == 2
