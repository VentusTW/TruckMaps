import json

import pytest
import sprawdz
from sprawdz import TESTS, compare_route


@pytest.mark.parametrize(
    ("new", "current", "ok"),
    [
        (100.0, 100.0, True),
        (114.0, 100.0, True),
        (116.0, 100.0, False),  # np. zgubiony most – duży objazd
        (80.0, 100.0, False),
        (100.0, None, True),  # trasy nie było w obecnych danych (nowy kraj)
        (None, 100.0, False),  # zniknęła z nowych danych
    ],
)
def test_compare_route(new, current, ok):
    assert compare_route("A → B", new, current, tolerance=0.15).ok is ok


def test_check_routes_compares_new_with_current(monkeypatch):
    lengths = {"http://nowe": 120.0, "http://obecne": 100.0}
    monkeypatch.setattr(sprawdz, "route_km", lambda base, start, end, vehicle: lengths[base])
    tests = {
        "trasy": [{"nazwa": "A → B", "z": [50, 20], "do": [51, 21]}],
        "pojazd": {},
        "tolerancja_dlugosci": 0.15,
    }

    (result,) = sprawdz.check_routes(tests, "http://nowe", "http://obecne")

    assert not result.ok
    assert "+20.0%" in result.details


def test_search_requires_expected_country(monkeypatch):
    answers = {
        "Tuchów": {"features": [{"properties": {"name": "Tuchów", "countrycode": "PL"}}]},
        "Wilno": {"features": []},
    }
    monkeypatch.setattr(
        sprawdz, "http_json", lambda url: answers["Tuchów" if "Tuch" in url else "Wilno"]
    )
    tests = {
        "wyszukiwanie": [
            {"zapytanie": "Tuchów", "kraj": "PL"},
            {"zapytanie": "Wilno", "kraj": "LT"},
        ]
    }

    results = sprawdz.check_search(tests, "http://photon")

    assert [r.ok for r in results] == [True, False]


def test_project_test_set_is_valid():
    tests = json.loads(TESTS.read_text(encoding="utf-8"))
    assert 0 < tests["tolerancja_dlugosci"] < 1
    assert all(len(r["z"]) == 2 and len(r["do"]) == 2 for r in tests["trasy"])
    assert {case["kraj"] for case in tests["wyszukiwanie"]} >= {"PL", "DE", "CZ", "SK", "LT"}
