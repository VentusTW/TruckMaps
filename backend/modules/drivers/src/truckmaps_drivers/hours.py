"""Czas jazdy i odpoczynku według rozporządzenia (WE) 561/2006 – naruszenia i liczniki.

Wejście to odcinki aktywności jednego kierowcy (UTC). Przerwy w danych i aktywność nieznana
(karta wyjęta) liczą się jako odpoczynek. Sprawdzamy:

* dzienny czas jazdy 9 h, dwa razy w tygodniu do 10 h (art. 6 ust. 1),
* tygodniowy 56 h i dwutygodniowy 90 h (art. 6 ust. 2–3),
* przerwę 45 min po 4,5 h jazdy, dzieloną 15 + 30 min (art. 7),
* odpoczynek dobowy 11 h w ciągu 24 h od końca poprzedniego, dzielony 3 + 9 h, skrócony 9 h
  najwyżej 3 razy między odpoczynkami tygodniowymi (art. 8 ust. 2 i 4),
* odpoczynek tygodniowy 45 h / skrócony 24 h, rozpoczęty najpóźniej po sześciu okresach
  24-godzinnych, bez dwóch skróconych z rzędu (art. 8 ust. 6).

Waga naruszeń według załącznika III do dyrektywy 2006/22/WE (rozporządzenie 2016/403):
``minor`` (drobne), ``serious`` (poważne), ``very_serious`` (bardzo poważne). Załoga
wieloosobowa (21 h na 9 h odpoczynku) i promy/pociągi nie są uwzględniane.
"""

from dataclasses import dataclass, field
from datetime import datetime, timedelta

H = 60
DAILY_DRIVING = 9 * H
EXTENDED_DRIVING = 10 * H
EXTENSIONS_PER_WEEK = 2
WEEKLY_DRIVING = 56 * H
FORTNIGHT_DRIVING = 90 * H
CONTINUOUS_DRIVING = 4 * H + 30
BREAK = 45
BREAK_FIRST = 15
BREAK_SECOND = 30
DAILY_REST = 11 * H
REDUCED_DAILY_REST = 9 * H
SPLIT_FIRST = 3 * H
REDUCED_DAILY_PER_WEEK = 3
WEEKLY_REST = 45 * H
REDUCED_WEEKLY_REST = 24 * H
WEEKLY_REST_WITHIN = 144 * H
PERIOD_SEPARATOR = 7 * H
"""Odpoczynek co najmniej tak długi kończy okres pracy (krótszy od 9 h – naruszenie)."""

# Progi wagi: (przekroczenie od, poważne od, bardzo poważne od) w minutach.
OVER = {
    "daily_driving_9": (DAILY_DRIVING, 10 * H, 11 * H),
    "daily_driving_10": (EXTENDED_DRIVING, 11 * H, 12 * H),
    "weekly_driving": (WEEKLY_DRIVING, 60 * H, 65 * H),
    "fortnight_driving": (FORTNIGHT_DRIVING, 100 * H, 112 * H + 30),
    "break": (CONTINUOUS_DRIVING, 5 * H, 6 * H),
    "weekly_rest_late": (0, 3 * H, 12 * H),
}
# Odpoczynki: (wymagane, drobne od, poważne od) – poniżej ostatniego bardzo poważne.
UNDER = {
    "daily_rest_11": (DAILY_REST, 10 * H, 8 * H + 30),
    "daily_rest_9": (REDUCED_DAILY_REST, 8 * H, 7 * H),
    "weekly_rest_45": (WEEKLY_REST, 42 * H, 36 * H),
    "weekly_rest_24": (REDUCED_WEEKLY_REST, 22 * H, 20 * H),
}


@dataclass
class Segment:
    start: datetime
    end: datetime
    activity: str

    @property
    def minutes(self) -> float:
        return (self.end - self.start).total_seconds() / 60


@dataclass
class Violation:
    kind: str
    """daily_driving, weekly_driving, fortnight_driving, break, daily_rest, weekly_rest,
    weekly_rest_late."""
    severity: str
    start: datetime
    end: datetime
    value: float
    """Minuty: czas jazdy, odpoczynku albo spóźnienia."""
    limit: float


@dataclass
class Counters:
    at: datetime | None = None
    """Stan na koniec danych."""
    continuous_driving: float = 0
    continuous_limit: float = CONTINUOUS_DRIVING
    daily_driving: float = 0
    daily_limit: float = EXTENDED_DRIVING
    extensions_left: int = EXTENSIONS_PER_WEEK
    daily_rest_due: datetime | None = None
    """Najpóźniejszy początek odpoczynku dobowego."""
    reduced_rests_left: int = REDUCED_DAILY_PER_WEEK
    weekly_driving: float = 0
    weekly_limit: float = WEEKLY_DRIVING
    fortnight_driving: float = 0
    fortnight_limit: float = FORTNIGHT_DRIVING
    weekly_rest_due: datetime | None = None
    """Najpóźniejszy początek odpoczynku tygodniowego."""
    last_weekly_rest: datetime | None = None


@dataclass
class Analysis:
    violations: list[Violation] = field(default_factory=list)
    counters: Counters = field(default_factory=Counters)


def severity_over(rule: str, value: float) -> str | None:
    limit, serious, very = OVER[rule]
    if value <= limit:
        return None
    return "very_serious" if value >= very else "serious" if value >= serious else "minor"


def severity_under(rule: str, value: float) -> str | None:
    required, minor, serious = UNDER[rule]
    if value >= required:
        return None
    return "minor" if value >= minor else "serious" if value >= serious else "very_serious"


def timeline(items: list[Segment]) -> list[Segment]:
    """Ciągła oś: jazda, praca, dyspozycyjność, odpoczynek (też luki i aktywność nieznana);
    nakładające się odcinki – późniejszy wygrywa od swojego początku."""
    result: list[Segment] = []
    for item in sorted(items, key=lambda s: s.start):
        kind = item.activity if item.activity in ("driving", "work", "available") else "rest"
        start, end = item.start, item.end
        if result and start < result[-1].end:
            if end <= result[-1].end:
                continue
            start = result[-1].end
        if result and start > result[-1].end:
            gap = Segment(result[-1].end, start, "rest")
            _append(result, gap)
        if end > start:
            _append(result, Segment(start, end, kind))
    return result


def _append(result: list[Segment], item: Segment) -> None:
    if result and result[-1].activity == item.activity and result[-1].end == item.start:
        result[-1] = Segment(result[-1].start, item.end, item.activity)
    else:
        result.append(item)


def _week(moment: datetime) -> datetime:
    """Początek tygodnia (poniedziałek 00:00 UTC)."""
    day = moment.replace(hour=0, minute=0, second=0, microsecond=0)
    return day - timedelta(days=day.weekday())


def _driving_by_week(line: list[Segment]) -> dict[datetime, float]:
    weeks: dict[datetime, float] = {}
    for item in line:
        if item.activity != "driving":
            continue
        start = item.start
        while start < item.end:
            boundary = _week(start) + timedelta(days=7)
            end = min(item.end, boundary)
            weeks[_week(start)] = weeks.get(_week(start), 0) + (end - start).total_seconds() / 60
            start = end
    return weeks


def analyse(items: list[Segment]) -> Analysis:
    line = timeline(items)
    result = Analysis()
    if not line:
        return result
    found = result.violations
    counters = result.counters
    counters.at = line[-1].end

    # Przerwy (art. 7).
    driving = 0.0
    first_part = False
    block_start = None
    for item in line:
        if item.activity == "driving":
            if driving == 0:
                block_start = item.start
            driving += item.minutes
        elif item.activity == "rest":
            minutes = item.minutes
            closes = minutes >= BREAK or (first_part and minutes >= BREAK_SECOND)
            if closes:
                level = severity_over("break", driving)
                if level and block_start is not None:
                    found.append(
                        Violation(
                            "break", level, block_start, item.start, driving, CONTINUOUS_DRIVING
                        )
                    )
                driving, first_part, block_start = 0.0, False, None
            elif minutes >= BREAK_FIRST and driving > 0:
                first_part = True
    counters.continuous_driving = driving

    # Okresy pracy między odpoczynkami dobowymi (art. 6 ust. 1, art. 8).
    rests = [
        i for i, s in enumerate(line) if s.activity == "rest" and s.minutes >= PERIOD_SEPARATOR
    ]
    extensions: dict[datetime, int] = {}
    reduced_since_weekly = 0
    previous_end: datetime | None = None
    begin = 0
    weekly: list[Segment] = []
    for index in [*rests, None]:
        period = line[begin:index] if index is not None else line[begin:]
        rest = line[index] if index is not None else None
        if period or index is None:
            start = period[0].start if period else line[-1].end
            minutes = sum(s.minutes for s in period if s.activity == "driving")
            week = _week(start)
            used = extensions.get(week, 0)
            if index is None:
                counters.daily_driving = minutes
                counters.extensions_left = max(0, EXTENSIONS_PER_WEEK - used)
                counters.daily_limit = (
                    EXTENDED_DRIVING if used < EXTENSIONS_PER_WEEK else DAILY_DRIVING
                )
            elif minutes > DAILY_DRIVING:
                rule = "daily_driving_9"
                if used < EXTENSIONS_PER_WEEK:
                    extensions[week] = used + 1
                    rule = "daily_driving_10"
                level = severity_over(rule, minutes)
                if level:
                    found.append(
                        Violation(
                            "daily_driving", level, start, period[-1].end, minutes, OVER[rule][0]
                        )
                    )
        if rest is not None and previous_end is not None:
            window_end = previous_end + timedelta(hours=24)
            in_window = max(0.0, (min(rest.end, window_end) - rest.start).total_seconds() / 60)
            split = any(s.activity == "rest" and s.minutes >= SPLIT_FIRST for s in period)
            if in_window >= DAILY_REST or (split and in_window >= REDUCED_DAILY_REST):
                pass
            elif in_window >= REDUCED_DAILY_REST and reduced_since_weekly < REDUCED_DAILY_PER_WEEK:
                reduced_since_weekly += 1
            else:
                rule = (
                    "daily_rest_9"
                    if reduced_since_weekly < REDUCED_DAILY_PER_WEEK
                    and in_window < REDUCED_DAILY_REST
                    else "daily_rest_11"
                )
                if rule == "daily_rest_9":
                    reduced_since_weekly += 1
                level = severity_under(rule, in_window)
                if level:
                    found.append(
                        Violation(
                            "daily_rest", level, rest.start, rest.end, in_window, UNDER[rule][0]
                        )
                    )
        if rest is not None:
            if rest.minutes >= REDUCED_WEEKLY_REST:
                weekly.append(rest)
                reduced_since_weekly = 0
            previous_end = rest.end
            begin = index + 1
    if previous_end is not None:
        counters.reduced_rests_left = max(0, REDUCED_DAILY_PER_WEEK - reduced_since_weekly)
        reduced = counters.reduced_rests_left > 0
        counters.daily_rest_due = (
            previous_end
            + timedelta(hours=24)
            - timedelta(minutes=REDUCED_DAILY_REST if reduced else DAILY_REST)
        )

    # Tygodniowy i dwutygodniowy czas jazdy (art. 6 ust. 2–3).
    weeks = _driving_by_week(line)
    for week, minutes in sorted(weeks.items()):
        level = severity_over("weekly_driving", minutes)
        if level:
            found.append(
                Violation(
                    "weekly_driving", level, week, week + timedelta(days=7), minutes, WEEKLY_DRIVING
                )
            )
        pair = minutes + weeks.get(week - timedelta(days=7), 0)
        level = severity_over("fortnight_driving", pair)
        if level:
            found.append(
                Violation(
                    "fortnight_driving", level, week - timedelta(days=7), week + timedelta(days=7),
                    pair, FORTNIGHT_DRIVING,
                )
            )  # fmt: skip
    current = _week(line[-1].end - timedelta(microseconds=1))
    counters.weekly_driving = weeks.get(current, 0)
    counters.fortnight_driving = counters.weekly_driving + weeks.get(current - timedelta(days=7), 0)

    # Odpoczynek tygodniowy (art. 8 ust. 6).
    for before, after in zip(weekly, weekly[1:], strict=False):
        late = (after.start - before.end).total_seconds() / 60 - WEEKLY_REST_WITHIN
        level = severity_over("weekly_rest_late", late)
        if level:
            found.append(
                Violation(
                    "weekly_rest_late", level, before.end, after.start, late, WEEKLY_REST_WITHIN
                )
            )
        if before.minutes < WEEKLY_REST and after.minutes < WEEKLY_REST:
            level = severity_under("weekly_rest_45", after.minutes)
            if level:
                found.append(
                    Violation(
                        "weekly_rest", level, after.start, after.end, after.minutes, WEEKLY_REST
                    )
                )
    if weekly:
        last = weekly[-1]
        counters.last_weekly_rest = last.end
        counters.weekly_rest_due = last.end + timedelta(minutes=WEEKLY_REST_WITHIN)
        open_late = (line[-1].end - counters.weekly_rest_due).total_seconds() / 60
        level = severity_over("weekly_rest_late", open_late) if last is not line[-1] else None
        if level:
            found.append(
                Violation(
                    "weekly_rest_late", level, last.end, line[-1].end, open_late, WEEKLY_REST_WITHIN
                )
            )
    found.sort(key=lambda v: v.start)
    return result
