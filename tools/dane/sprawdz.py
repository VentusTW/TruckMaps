"""Kontrola nowych danych (trasy Valhalli, wyszukiwarka Photon) przed podmianą.

    python tools/dane/sprawdz.py trasy --nowe http://127.0.0.1:8003 [--obecne http://127.0.0.1:8002]
    python tools/dane/sprawdz.py wyszukiwarka --adres http://127.0.0.1:2323

Zestaw tras i zapytań: infra/testy_danych.json. Kod wyjścia 0 = dane dobre, 1 = nie
podmieniać. Trasa musi istnieć w nowych danych, a jej długość nie może odbiegać od obecnej
o więcej niż tolerancja (np. zgubiony most albo przejście graniczne). Sama biblioteka
standardowa – adresy są lokalne, więc bez problemów z certyfikatami.
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

TESTS = Path(__file__).resolve().parents[2] / "infra" / "testy_danych.json"
TIMEOUT_S = 60


@dataclass
class Result:
    name: str
    ok: bool
    details: str


def http_json(url: str, body: dict | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data, {"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_S) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:  # Valhalla zwraca błędy jako JSON z kodem 400
        return json.load(exc)


def route_km(base: str, start: list[float], end: list[float], vehicle: dict) -> float | None:
    body = {
        "locations": [{"lat": start[0], "lon": start[1]}, {"lat": end[0], "lon": end[1]}],
        "costing": "truck",
        "costing_options": {"truck": vehicle},
    }
    trip = http_json(f"{base.rstrip('/')}/route", body).get("trip")
    return trip["summary"]["length"] if trip else None


def compare_route(name: str, new: float | None, current: float | None, tolerance: float) -> Result:
    """Ocena jednej trasy: brak w nowych danych albo duża zmiana długości = błąd."""
    if new is None:
        return Result(name, False, "brak trasy w nowych danych")
    if current is None:
        return Result(name, True, f"{new:.0f} km (obecne dane nie mają tej trasy)")
    change = new / current - 1
    details = f"{new:.0f} km, obecnie {current:.0f} km ({change:+.1%})"
    return Result(name, abs(change) <= tolerance, details)


def check_routes(tests: dict, new: str, current: str | None) -> list[Result]:
    results = []
    for route in tests["trasy"]:
        new_km = route_km(new, route["z"], route["do"], tests["pojazd"])
        current_km = None
        if current:
            try:
                current_km = route_km(current, route["z"], route["do"], tests["pojazd"])
            except OSError:
                current = None  # obecny serwer nie działa – sprawdzamy tylko istnienie tras
        results.append(
            compare_route(route["nazwa"], new_km, current_km, tests["tolerancja_dlugosci"])
        )
    return results


def check_search(tests: dict, base: str) -> list[Result]:
    results = []
    for case in tests["wyszukiwanie"]:
        query = urllib.parse.urlencode({"q": case["zapytanie"], "limit": 1, "lang": "pl"})
        started = time.monotonic()
        features = http_json(f"{base.rstrip('/')}/api?{query}").get("features", [])
        seconds = time.monotonic() - started
        found = features[0]["properties"] if features else {}
        country = found.get("countrycode", "")
        label = found.get("name") or found.get("street") or "brak wyniku"
        ok = country == case["kraj"]
        details = f"{label} ({country or '-'}), {seconds:.2f} s"
        results.append(Result(case["zapytanie"], ok, details))
    return results


def wait_until_ready(url: str, seconds: int) -> None:
    deadline = time.monotonic() + seconds
    while True:
        try:
            urllib.request.urlopen(url, timeout=10).close()
            return
        except OSError:
            if time.monotonic() > deadline:
                raise SystemExit(f"Serwer {url} nie odpowiada od {seconds} s") from None
            time.sleep(5)


def report(results: list[Result]) -> bool:
    for result in results:
        print(f"  {'OK ' if result.ok else 'ZLE'} {result.name}: {result.details}")
    failed = sum(not r.ok for r in results)
    print(f"Wynik: {len(results) - failed}/{len(results)} poprawnych")
    return failed == 0


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Kontrola nowych danych przed podmianą.")
    parser.add_argument("--testy", type=Path, default=TESTS)
    parser.add_argument("--czekaj", type=int, default=600, help="ile sekund czekać na serwer")
    commands = parser.add_subparsers(dest="command", required=True)
    routes = commands.add_parser("trasy")
    routes.add_argument("--nowe", required=True, help="Valhalla z nowymi danymi")
    routes.add_argument("--obecne", help="Valhalla z obecnymi danymi (do porównania)")
    search = commands.add_parser("wyszukiwarka")
    search.add_argument("--adres", required=True, help="Photon z nowymi danymi")
    args = parser.parse_args(argv)
    sys.stdout.reconfigure(errors="replace")

    tests = json.loads(args.testy.read_text(encoding="utf-8"))
    if args.command == "trasy":
        wait_until_ready(f"{args.nowe.rstrip('/')}/status", args.czekaj)
        print(f"Kontrola tras: {args.nowe}")
        ok = report(check_routes(tests, args.nowe, args.obecne))
    else:
        wait_until_ready(f"{args.adres.rstrip('/')}/api?q=a&limit=1", args.czekaj)
        print(f"Kontrola wyszukiwarki: {args.adres}")
        ok = report(check_search(tests, args.adres))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
