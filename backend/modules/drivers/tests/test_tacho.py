import contextlib
import random
from datetime import UTC, datetime, timedelta

import pytest
from truckmaps_drivers import hours, tacho

MON = datetime(2026, 11, 2, tzinfo=UTC)


def _change(activity, minute, **kwargs):
    acts = {"rest": 0, "available": 1, "work": 2, "driving": 3}
    slot, crew, absent, known = (kwargs.get(k, False) for k in ("slot", "crew", "absent", "known"))
    c = known if absent else crew
    return int(slot) << 15 | int(c) << 14 | int(absent) << 13 | acts[activity] << 11 | minute


DAY1 = [
    _change("rest", 0),
    _change("work", 360),
    _change("driving", 375),
    _change("rest", 645),
    _change("driving", 690),
    _change("work", 930),
    _change("rest", 960),
]
DAY2 = [
    _change("rest", 0),
    _change("driving", 360),
    _change("rest", 660),
    _change("rest", 1200, absent=True),
]


@pytest.mark.parametrize("generation", [1, 2])
def test_card_file_activities_places_and_holder(ddd, generation):
    data = ddd.card(
        {MON: DAY1, MON + timedelta(days=1): DAY2},
        generation=generation,
        places=[(MON.replace(hour=6), 0, 120000), (MON.replace(hour=16), 1, 120650)],
    )
    parsed = tacho.parse(data)
    assert parsed.kind == "card" and parsed.generation == generation
    assert parsed.card_number == ddd.CARD + "00"
    assert parsed.holder_name == "Jan Kowalski"
    assert parsed.nation == "PL" and str(parsed.birth_date) == "1980-03-15"
    assert str(parsed.card_expiry) == "2027-01-01"
    kinds = [(a.activity, a.start.strftime("%d %H:%M"), a.minutes) for a in parsed.activities]
    assert kinds[:5] == [
        ("rest", "02 00:00", 360),
        ("work", "02 06:00", 15),
        ("driving", "02 06:15", 270),
        ("rest", "02 10:45", 45),
        ("driving", "02 11:30", 240),
    ]
    # Odpoczynek przez północ jako jeden odcinek, karta wyjęta – aktywność nieznana.
    assert ("rest", "02 16:00", 840) in kinds
    assert kinds[-1] == ("unknown", "03 20:00", 240)
    assert parsed.period_start == MON and parsed.period_end == MON + timedelta(days=2)
    assert [(p.entry, p.country, p.odometer) for p in parsed.places] == [
        ("begin", "PL", 120000),
        ("end", "PL", 120650),
    ]
    if generation == 2:
        assert parsed.places[0].lat == pytest.approx(52.225) and parsed.places[
            0
        ].lon == pytest.approx(21.01)


def test_card_without_wraparound_and_manual_entry(ddd):
    words = [
        _change("rest", 0),
        _change("work", 480, absent=True, known=True),
        _change("rest", 540),
    ]
    parsed = tacho.parse(ddd.card({MON: words}, wrap=False))
    work = next(a for a in parsed.activities if a.activity == "work")
    assert work.manual and work.minutes == 60


def test_vehicle_unit_gen1_and_gen2(ddd):
    words = [
        _change("rest", 0),
        _change("driving", 360),
        _change("rest", 600),
        _change("rest", 0, slot=1),
    ]
    first = tacho.parse(ddd.vu1(MON, words))
    assert first.kind == "vu" and first.generation == 1
    assert first.vin == "WMA06XZZ0NP123456" and first.plate == "WX 12345"
    assert first.period_start == MON
    driving = [a for a in first.activities if a.activity == "driving"]
    assert [(a.card_number, a.holder_name, a.minutes) for a in driving] == [
        (ddd.CARD + "00", "Jan Kowalski", 240)
    ]
    # Szczelina drugiego kierowcy bez karty – pomijana.
    assert {a.slot for a in first.activities} == {0}
    assert first.places[0].card_number == ddd.CARD + "00" and first.places[0].odometer == 1000

    words2 = [
        _change("work", 0, slot=1),
        _change("driving", 600, slot=1),
        _change("rest", 1260, slot=1),
    ]
    second = tacho.parse(ddd.vu2(MON, words2))
    assert second.generation == 2 and second.plate == "WX 12345"
    # Karta wyjęta o 20:00 – reszta doby bez kierowcy.
    assert [(a.activity, a.minutes, a.holder_name) for a in second.activities] == [
        ("work", 600, "Adam Nowak"),
        ("driving", 660, "Adam Nowak"),
    ]
    assert second.cards() == {"PL000099999900": "Adam Nowak"}


@pytest.mark.parametrize(
    ("data", "code"),
    [
        (b"hello world, not a tacho file", "tacho.not_ddd"),
        (b"\x00\x02\x00\x00\x19" + bytes(25), "tacho.not_card"),
        (b"\x00\x02\x00\xff\xff" + bytes(10), "tacho.truncated"),
    ],
)
def test_bad_files(data, code):
    with pytest.raises(tacho.TachoError) as error:
        tacho.parse(data)
    assert error.value.code == code


def test_corrupted_files_never_crash(ddd):
    """Ucięte i przekłamane pliki – zawsze TachoError (422), nigdy błąd serwera."""
    words = [
        _change("rest", 0),
        _change("driving", 360),
        _change("rest", 600),
        _change("rest", 0, slot=1),
    ]
    seeds = [
        ddd.card({MON: DAY1}, generation=1),
        ddd.card({MON: DAY1}, generation=2),
        ddd.vu1(MON, words),
        ddd.vu2(MON, words),
    ]
    rng = random.Random(7)
    for _ in range(2000):
        data = bytearray(rng.choice(seeds))
        if rng.random() < 0.4:
            data = data[: rng.randint(2, len(data))]
        for _ in range(rng.randint(1, 8)):
            data[rng.randrange(len(data))] = rng.randrange(256)
        with contextlib.suppress(tacho.TachoError):
            tacho.parse(bytes(data))


# ── 561/2006 ──────────────────────────────────────────────────────────────────────────────────


def day(start: datetime, *chunks: tuple[str, int]) -> list[hours.Segment]:
    """Odcinki od ``start`` (aktywność, minuty)."""
    result = []
    for activity, minutes in chunks:
        end = start + timedelta(minutes=minutes)
        result.append(hours.Segment(start, end, activity))
        start = end
    return result


def workday(date: datetime, driving: list[int], start_hour: int = 6) -> list[hours.Segment]:
    chunks: list[tuple[str, int]] = []
    for i, minutes in enumerate(driving):
        if i:
            chunks.append(("rest", 45))
        chunks.append(("driving", minutes))
    return day(date.replace(hour=start_hour), *chunks)


def kinds(analysis: hours.Analysis) -> list[tuple[str, str]]:
    return [(v.kind, v.severity) for v in analysis.violations]


def test_daily_driving_extensions_twice_a_week():
    segments = []
    for i, minutes in enumerate([[270, 270, 30]] * 3 + [[270, 270, 150]]):
        segments += workday(MON + timedelta(days=i), minutes)
    segments += workday(MON + timedelta(days=4), [60])
    result = hours.analyse(segments)
    assert kinds(result) == [("daily_driving", "minor"), ("daily_driving", "very_serious")]
    assert result.violations[0].limit == 540 and result.violations[0].value == 570
    assert result.violations[1].value == 690
    assert result.counters.extensions_left == 0 and result.counters.daily_limit == 540


def test_extended_day_over_ten_hours():
    result = hours.analyse(workday(MON, [270, 270, 100]) + workday(MON + timedelta(days=1), [60]))
    assert kinds(result) == [("daily_driving", "minor")]
    assert result.violations[0].limit == 600


def test_break_rules_and_split_break():
    result = hours.analyse(
        day(MON.replace(hour=6), ("driving", 300), ("rest", 60), ("driving", 60))
    )
    assert kinds(result) == [("break", "serious")]
    split = day(
        MON.replace(hour=6), ("driving", 120), ("rest", 15), ("driving", 150), ("rest", 30),
        ("driving", 120), ("work", 30), ("rest", 20),
    )  # fmt: skip
    result = hours.analyse(split)
    assert kinds(result) == []
    assert result.counters.continuous_driving == 120
    # Kolejność 30 + 15 nie jest przerwą dzieloną.
    wrong = day(
        MON.replace(hour=6),
        ("driving", 120),
        ("rest", 30),
        ("driving", 150),
        ("rest", 15),
        ("driving", 30),
    )
    assert kinds(hours.analyse(wrong)) == []
    assert hours.analyse(wrong).counters.continuous_driving == 300


def test_reduced_and_short_daily_rest():
    segments = day(
        MON - timedelta(hours=6), ("rest", 720), ("driving", 240), ("rest", 45), ("work", 660),
        ("rest", 480), ("driving", 120), ("rest", 900),
    )  # fmt: skip
    result = hours.analyse(segments)
    assert kinds(result) == [("daily_rest", "minor")]
    assert result.violations[0].value == 480 and result.violations[0].limit == 540
    reduced = day(
        MON - timedelta(hours=6), ("rest", 720), ("driving", 240), ("rest", 45), ("work", 555),
        ("rest", 600), ("driving", 120), ("rest", 900),
    )  # fmt: skip
    result = hours.analyse(reduced)
    assert kinds(result) == []
    assert result.counters.reduced_rests_left == 2


def test_weekly_and_fortnight_driving():
    segments = []
    for i in range(7):
        segments += workday(MON + timedelta(days=i), [270, 270])
    result = hours.analyse(segments)
    assert ("weekly_driving", "serious") in kinds(result)
    weekly = next(v for v in result.violations if v.kind == "weekly_driving")
    assert weekly.value == 63 * 60 and weekly.start == MON
    for i in range(7, 12):
        segments += workday(MON + timedelta(days=i), [270, 270])
    result = hours.analyse(segments)
    assert ("fortnight_driving", "serious") in kinds(result)
    assert result.counters.fortnight_driving == 12 * 9 * 60
    assert result.counters.weekly_driving == 5 * 9 * 60


def test_weekly_rest_late_and_reduced_twice():
    segments = day(datetime(2026, 10, 31, 9, tzinfo=UTC), ("rest", 45 * 60))
    for i in range(7):
        segments += day(MON + timedelta(days=i, hours=6), ("driving", 240))
    sunday = MON + timedelta(days=6, hours=10)
    segments += day(sunday, ("rest", 25 * 60), ("driving", 120), ("rest", 25 * 60), ("driving", 60))
    result = hours.analyse(segments)
    late = next(v for v in result.violations if v.kind == "weekly_rest_late")
    assert late.severity == "serious" and late.value == 4 * 60
    assert ("weekly_rest", "very_serious") in kinds(result)
    assert result.counters.weekly_rest_due is not None


def test_counters_and_unknown_as_rest():
    segments = day(MON.replace(hour=6), ("driving", 180), ("unknown", 10), ("work", 20))
    result = hours.analyse(segments)
    assert result.counters.continuous_driving == 180
    assert result.counters.daily_driving == 180
    assert result.counters.weekly_driving == 180
    assert result.counters.at == MON.replace(hour=9, minute=30)
    assert hours.analyse([]).counters.at is None


@pytest.mark.parametrize(
    ("rule", "value", "expected"),
    [
        ("daily_driving_9", 540, None),
        ("daily_driving_9", 541, "minor"),
        ("daily_driving_9", 600, "serious"),
        ("daily_driving_9", 660, "very_serious"),
        ("break", 300, "serious"),
        ("weekly_driving", 3900, "very_serious"),
    ],
)
def test_severity_over(rule, value, expected):
    assert hours.severity_over(rule, value) == expected


@pytest.mark.parametrize(
    ("rule", "value", "expected"),
    [
        ("daily_rest_11", 660, None),
        ("daily_rest_11", 600, "minor"),
        ("daily_rest_11", 510, "serious"),
        ("daily_rest_11", 500, "very_serious"),
        ("weekly_rest_24", 1350, "minor"),
        ("weekly_rest_24", 1100, "very_serious"),
    ],
)
def test_severity_under(rule, value, expected):
    assert hours.severity_under(rule, value) == expected
