"""Progi oceny trasy w jednym miejscu – do strojenia bez przebudowy programu.

Wartości domyślne są tutaj. Plik JSON wskazany w ``TRUCKMAPS_ROUTE_THRESHOLDS`` (domyślnie
``infra/route_thresholds.json``, jeśli istnieje) nadpisuje wybrane pola, np.::

    {"long_vehicle_m": 13.5, "bend_orange_factor": 0.55}

Plik jest wczytywany ponownie po zmianie (data modyfikacji), więc nowe progi działają od
następnej trasy, bez restartu serwera. Błędny plik albo nieznane pole – zostają poprzednie
wartości i ostrzeżenie w logu. Wzór ze wszystkimi polami: ``infra/route_thresholds.example.json``.
"""

import json
import logging
import os
import threading
from dataclasses import asdict, dataclass, fields, replace
from pathlib import Path

log = logging.getLogger(__name__)

ENV = "TRUCKMAPS_ROUTE_THRESHOLDS"
DEFAULT_PATH = Path("infra/route_thresholds.json")


@dataclass(frozen=True)
class Thresholds:
    # Zakręty: promień łuku względem długości pojazdu, ograniczony z dołu i z góry (m).
    bend_yellow_factor: float = 0.9
    bend_yellow_min_m: float = 8.0
    bend_yellow_max_m: float = 20.0
    bend_orange_factor: float = 0.6
    bend_orange_min_m: float = 6.0
    bend_orange_max_m: float = 12.0
    bend_spacing_m: float = 10.0
    """Odległość punktów, z których liczony jest promień łuku."""

    # Wąskie drogi i ulice osiedlowe.
    long_vehicle_m: float = 12.0
    """Dłuższy pojazd: ulica osiedlowa pomarańczowa, droga lokalna żółta."""
    medium_vehicle_m: float = 8.0
    """Dłuższy pojazd: ulica osiedlowa żółta."""
    wide_road_m: float = 6.0
    """Jezdnia (tag ``width``) od tej szerokości nie jest ciasna."""
    narrow_road_m: float = 4.5
    """Poniżej – ciasno także w strefie przemysłowej."""
    wide_lanes: int = 2
    """Tyle pasów w kierunku jazdy – ulica nie jest ciasna."""
    end_zone_m: float = 1000.0
    """Dojazd do startu i celu: ulica osiedlowa tylko żółta."""
    transit_zone_m: float = 5000.0
    """Strefa „tylko dojazd” dalej niż tyle od końców trasy to przejazd tranzytem."""

    # Zapas do zmierzonego prześwitu bez znaku (m) – mniej: pomarańczowy i omijany.
    measured_height_margin_m: float = 0.20
    measured_width_margin_m: float = 0.30

    # Punkty przy trasie (fotoradary, sygnalizacja, odcinki pomiaru) – odległość od linii trasy.
    point_on_route_m: float = 25.0
    signals_on_route_m: float = 12.0
    line_on_route_m: float = 15.0
    line_merge_gap_m: float = 150.0
    line_min_m: float = 100.0

    # Planowanie po zielonych drogach.
    max_detour_factor: float = 1.25
    max_detour_extra_km: float = 3.0
    keep_near_stops_m: float = 400.0
    """Trudne miejsca bliżej punktów trasy nie są omijane (i tak trzeba tam dojechać)."""

    # Numery domów tylko przy końcach trasy (0 – wyłączone).
    house_numbers_end_m: float = 400.0
    """Ile ostatnich metrów dojazdu do celu (i pierwszych odjazdu ze startu)."""
    house_numbers_side_m: float = 60.0
    """Jak daleko od linii trasy (budynki po obu stronach ulicy)."""

    def bend_radii(self, length_m: float) -> tuple[float, float]:
        """Promienie (żółty, pomarańczowy) dla pojazdu o długości ``length_m``."""
        yellow = min(
            max(self.bend_yellow_factor * length_m, self.bend_yellow_min_m), self.bend_yellow_max_m
        )
        orange = min(
            max(self.bend_orange_factor * length_m, self.bend_orange_min_m), self.bend_orange_max_m
        )
        return yellow, orange


DEFAULTS = Thresholds()
_lock = threading.Lock()
_cache: tuple[Path, float | None, Thresholds] | None = None


def parse(data: dict, base: Thresholds = DEFAULTS) -> Thresholds:
    """Nadpisuje pola ``base`` wartościami z ``data``.

    Nieznane pole albo zły typ – ``ValueError``.
    """
    known = {f.name: f.type for f in fields(Thresholds)}
    unknown = set(data) - set(known)
    if unknown:
        raise ValueError(f"nieznane progi: {', '.join(sorted(unknown))}")
    values = {}
    for name, value in data.items():
        if isinstance(value, bool) or not isinstance(value, int | float) or value < 0:
            raise ValueError(f"{name}: oczekiwana liczba ≥ 0")
        values[name] = int(value) if known[name] in (int, "int") else float(value)
    return replace(base, **values)


def _path() -> Path:
    return Path(os.environ.get(ENV) or DEFAULT_PATH)


def current() -> Thresholds:
    """Aktualne progi (plik wczytany ponownie po zmianie)."""
    global _cache
    path = _path()
    try:
        mtime = path.stat().st_mtime
    except OSError:
        mtime = None
    with _lock:
        if _cache is not None and _cache[0] == path and _cache[1] == mtime:
            return _cache[2]
        value = _cache[2] if _cache is not None else DEFAULTS
        if mtime is None:
            value = DEFAULTS
        else:
            try:
                value = parse(json.loads(path.read_text(encoding="utf-8")))
                log.info("Progi oceny trasy wczytane z %s", path)
            except (OSError, ValueError) as error:
                log.warning("Progi oceny trasy: plik %s pominięty (%s)", path, error)
        _cache = (path, mtime, value)
        return value


def as_dict(value: Thresholds | None = None) -> dict:
    return asdict(value or current())
