"""Ograniczenia warunkowe z OSM (``hgv:conditional``, ``maxweight:conditional`` …).

Składnia: ``wartość @ (warunek); wartość @ (warunek)``, np.
``hgv:conditional=no @ (Mo-Fr 06:00-22:00)``,
``motor_vehicle:conditional=no @ (weight>7.5 AND 22:00-06:00)``,
``access:conditional=no @ (Nov 01-May 31)``.

Warunek to godziny w składni ``opening_hours`` (dni tygodnia, święta ``PH``, miesiące
i daty, godziny – także przez północ, ``off``) i/lub warunki pojazdu (``weight>7.5``,
``length>12``), połączone ``AND``. Warunek dla grupy użytkowników (``@ destination``,
``@ agricultural`` …) to wyjątek dla tej grupy, nie dla zwykłego ruchu – pomijamy go.
Warunku, którego nie rozumiemy, nie zgadujemy: ``parse`` zwraca ``None``, a ocena trasy
pokazuje ostrzeżenie „sprawdź znak”.
"""

import re
from dataclasses import dataclass, field
from datetime import date, datetime

DAYS = {"mo": 0, "tu": 1, "we": 2, "th": 3, "fr": 4, "sa": 5, "su": 6}
MONTHS = {
    m: i + 1
    for i, m in enumerate(
        ("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec")
    )
}
# Grupy użytkowników: warunek dotyczy tylko ich (zwykle wyjątek od ograniczenia).
USER_GROUPS = {
    "destination", "delivery", "agricultural", "forestry", "marked", "private", "bus",
    "official", "customers", "permit", "permissive", "emergency", "psv", "taxi", "residents",
    "disabled", "school", "tourist_bus", "coach", "goods", "hgv", "military", "service",
    "public_transport", "designated",
}  # fmt: skip
VEHICLE_KEYS = {
    "weight": "weight_t", "maxweight": "weight_t", "length": "length_m",
    "weightrating": "gvw_t", "maxweightrating": "gvw_t",
}  # fmt: skip
_VEHICLE = re.compile(
    r"(weight|maxweight|length|weightrating|maxweightrating)\s*(>=|<=|>|<)\s*(\d+(?:[.,]\d+)?)\s*(t|m)?$"
)
# Wartości, które niczego nie zakazują – nieczytelny warunek przy nich można pominąć.
RELAXING = {"yes", "none", "permissive", "designated", "discouraged", "foot", "unsigned"}
_TIME = re.compile(r"(\d{1,2}):(\d{2})(?:\s*-\s*(\d{1,2}):(\d{2})|(\+))")
_DAY_RANGE = re.compile(r"(mo|tu|we|th|fr|sa|su)(?:-(mo|tu|we|th|fr|sa|su))?$")
_MON = r"(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)"
_MONTH_RANGE = re.compile(rf"{_MON}(?:-{_MON})?$")
# Zakres dat, np. "nov 01-may 31", "2025 mar 12-2025 dec 01", "dec 24-26".
_DATES = rf"(?:\d{{4}} )?{_MON} \d{{1,2}}-(?:\d{{4}} )?(?:{_MON} )?\d{{1,2}}"
_DATE_RANGE = re.compile(
    rf"(?:(\d{{4}}) )?{_MON} (\d{{1,2}})-(?:(\d{{4}}) )?(?:{_MON} )?(\d{{1,2}})$"
)
# Kolejna reguła po przecinku: "Mo-Fr 00:00-10:30,20:00-24:00, Sa 06:00-10:30".
_RULE_SEPARATOR = re.compile(r"(?<=\d),\s+(?=[a-z])")


@dataclass(frozen=True)
class Rule:
    """Jedna reguła godzin: dni (0 = poniedziałek), święta, miesiące, daty, minuty doby."""

    days: frozenset[int] | None = None
    holidays: bool = False
    months: frozenset[int] | None = None
    dates: tuple[tuple[tuple, tuple], ...] = ()
    """Zakresy dat ((rok|None, miesiąc, dzień), (rok|None, miesiąc, dzień)); bez roku – co roku."""
    minutes: tuple[tuple[int, int], ...] = ()
    """Przedziały [od, do) w minutach od północy; ``do`` < ``od`` – przez północ."""
    off: bool = False
    """Reguła wyłączająca (np. "PH off")."""

    def active(self, moment: datetime, holiday: bool) -> bool:
        if self.months is not None and moment.month not in self.months:
            return False
        if self.dates and not any(_in_dates(moment.date(), r) for r in self.dates):
            return False
        minute = moment.hour * 60 + moment.minute
        for start, end in self.minutes or ((0, 24 * 60),):
            if start < end and start <= minute < end:
                return self._on_day(moment.weekday(), holiday)
            if start >= end:  # przez północ: wieczór – ten dzień, rano – dzień poprzedni
                if minute >= start:
                    return self._on_day(moment.weekday(), holiday)
                if minute < end:
                    return self._on_day((moment.weekday() - 1) % 7, holiday)
        return False

    def _on_day(self, weekday: int, holiday: bool) -> bool:
        if self.days is None and not self.holidays:
            return True
        return (self.days is not None and weekday in self.days) or (self.holidays and holiday)


def _in_dates(day: date, span: tuple[tuple, tuple]) -> bool:
    (y1, m1, d1), (y2, m2, d2) = span
    if y1 is not None:
        try:
            return date(y1, m1, d1) <= day <= date(y2 or y1, m2, d2)
        except ValueError:
            return False
    first, last, current = (m1, d1), (m2, d2), (day.month, day.day)
    if first <= last:
        return first <= current <= last
    return current >= first or current <= last  # przez Nowy Rok, np. Nov 01-May 31


@dataclass(frozen=True)
class Condition:
    value: str
    """Np. "no", "destination", "7.5" (małymi literami)."""
    rules: tuple[Rule, ...] = ()
    """Reguły godzin (wystarczy jedna włączająca, bez wyłączającej); puste – bez czasu."""
    vehicle: tuple[tuple[str, str, float], ...] = field(default=())
    """Warunki pojazdu: (pole pojazdu, operator, wartość), np. ("weight_t", ">", 7.5)."""
    group: str | None = None
    """Grupa użytkowników, której dotyczy warunek; ``None`` – zwykły ruch."""

    @property
    def timed(self) -> bool:
        return bool(self.rules)

    def applies_to(self, vehicle) -> bool:
        if self.group is not None:
            return False
        for attribute, op, limit in self.vehicle:
            actual = getattr(vehicle, attribute, None) or 0
            ok = {
                ">": actual > limit,
                ">=": actual >= limit,
                "<": actual < limit,
                "<=": actual <= limit,
            }[op]
            if not ok:
                return False
        return True

    def active(self, moment: datetime, holiday: bool = False) -> bool:
        if not self.rules:
            return True
        on = [r for r in self.rules if not r.off]
        if any(r.active(moment, holiday) for r in self.rules if r.off):
            return False
        return not on or any(r.active(moment, holiday) for r in on)


def _split_top(text: str, sep: str) -> list[str]:
    """Dzieli po ``sep`` poza nawiasami."""
    parts, depth, current = [], 0, ""
    for char in text:
        depth += char == "("
        depth -= char == ")"
        if char == sep and depth == 0:
            parts.append(current)
            current = ""
        else:
            current += char
    parts.append(current)
    return [p.strip() for p in parts if p.strip()]


def _rule(text: str) -> Rule | None:
    days: set[int] = set()
    months: set[int] = set()
    dates: list[tuple[tuple, tuple]] = []
    holidays = off = False
    minutes: list[tuple[int, int]] = []
    text = re.sub(r"\s*-\s*", "-", text.lower()).replace(", ", ",")
    if found := re.search(_DATES, text):
        span = _DATE_RANGE.fullmatch(found.group(0))
        if not span:
            return None
        y1, m1, d1, y2, m2, d2 = span.groups()
        dates.append(
            ((int(y1) if y1 else None, MONTHS[m1], int(d1)),
             (int(y2) if y2 else (int(y1) if y1 else None), MONTHS[m2 or m1], int(d2)))
        )  # fmt: skip
        text = text.replace(found.group(0), " ")
    for token in text.split():
        if token == "24/7":
            continue
        if token == "off":
            off = True
            continue
        if _TIME.match(token):
            for item in token.split(","):
                found = _TIME.fullmatch(item)
                if not found:
                    return None
                h1, m1, h2, m2, open_end = found.groups()
                start = int(h1) * 60 + int(m1)
                end = 24 * 60 if open_end else int(h2) * 60 + int(m2)
                if start > 24 * 60 or end > 24 * 60:
                    return None
                minutes.append((start, end))
            continue
        for item in token.split(","):
            if item == "ph":
                holidays = True
            elif day := _DAY_RANGE.fullmatch(item):
                first = DAYS[day.group(1)]
                last = DAYS[day.group(2) or day.group(1)]
                days |= {(first + i) % 7 for i in range((last - first) % 7 + 1)}
            elif month := _MONTH_RANGE.fullmatch(item):
                first = MONTHS[month.group(1)]
                last = MONTHS[month.group(2) or month.group(1)]
                months |= {(first - 1 + i) % 12 + 1 for i in range((last - first) % 12 + 1)}
            else:
                return None
    return Rule(
        days=frozenset(days) if days else None,
        holidays=holidays,
        months=frozenset(months) if months else None,
        dates=tuple(dates),
        minutes=tuple(minutes),
        off=off,
    )


def restrictive(raw: str) -> bool:
    """Czy tag może coś zakazywać (wartość inna niż "yes", "none" …) – do „sprawdź znak”."""
    values = {part.partition("@")[0].strip().lower() for part in _split_top(raw, ";")}
    return bool(values - RELAXING - USER_GROUPS) or bool(values & {"private", "destination"})


def parse(raw: str) -> list[Condition] | None:
    """Warunki z wartości tagu ``*:conditional``; ``None`` – czegoś nie rozumiemy."""
    conditions = []
    for part in _split_top(raw, ";"):
        value, at, condition = part.partition("@")
        if not at:
            return None
        condition = condition.strip()
        if condition.startswith("(") and condition.endswith(")"):
            condition = condition[1:-1]
        rules, vehicle, group = [], [], None
        for piece in re.split(r"\s+AND\s+", condition, flags=re.IGNORECASE):
            piece = piece.strip().strip("()").strip()
            words = [w.strip() for w in re.split(r"[;,]", piece.lower())]
            if all(w in USER_GROUPS for w in words):
                group = words[0]
                continue
            if found := _VEHICLE.fullmatch(piece.lower()):
                key, op, number, _ = found.groups()
                vehicle.append((VEHICLE_KEYS[key], op, float(number.replace(",", "."))))
                continue
            for text in _split_top(piece, ";"):
                for rule_text in _RULE_SEPARATOR.split(text.lower()):
                    rule = _rule(rule_text)
                    if rule is None:
                        return None
                    rules.append(rule)
        conditions.append(Condition(value.strip().lower(), tuple(rules), tuple(vehicle), group))
    return conditions or None
