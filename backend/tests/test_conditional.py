from datetime import datetime

import pytest

from truckmaps.core import timebans
from truckmaps.core.conditional import parse, restrictive
from truckmaps.core.restrictions import Kind, Restriction, restrictions_from_tags
from truckmaps.core.route_analysis import RouteEdge, analyze
from truckmaps.core.vehicles import VehicleIn

TRUCK = VehicleIn(
    name="Zestaw", height_m=4, width_m=2.55, length_m=16.5, weight_t=40, axle_load_t=11.5,
    axle_count=5,
)  # fmt: skip
VAN = VehicleIn(
    name="Bus", height_m=2.7, width_m=2.1, length_m=6, weight_t=3.2, gvw_t=3.5, axle_load_t=2,
    axle_count=2, trailer_type="none",
)  # fmt: skip
SATURDAY_NIGHT = datetime(2026, 10, 31, 23, 30)
MONDAY_MORNING = datetime(2026, 11, 2, 7, 0)


def active(raw: str, moment: datetime, holiday: bool = False) -> list[str]:
    return [c.value for c in parse(raw) if c.active(moment, holiday)]


@pytest.mark.parametrize(
    ("raw", "night", "morning"),
    [
        ("no @ (Mo-Fr 06:00-22:00)", [], ["no"]),
        ("no @ (22:00-06:00)", ["no"], []),
        ("no @ (20:00+)", ["no"], []),
        ("no @ (00:00-06:00,22:00-24:00)", ["no"], []),
        ("destination @ (Sa,Su,PH)", ["destination"], []),
        ("no @ (Nov 01-May 31)", [], ["no"]),  # 31.10 jeszcze poza zakresem, 2.11 już w nim
        ("no @ (Mar 20 - Jul 15)", [], []),
        ("no @ (2014 Sep 22-2015 Nov 30)", [], []),
        ("delivery @ (Mo-Fr 00:00-10:30,20:00-24:00, Sa 06:00-10:30)", [], ["delivery"]),
    ],
)
def test_time_conditions(raw, night, morning):
    assert active(raw, SATURDAY_NIGHT) == night
    assert active(raw, MONDAY_MORNING) == morning


def test_public_holiday_and_off_rule():
    assert active("no @ (PH)", MONDAY_MORNING, holiday=True) == ["no"]
    assert active("delivery @ (Mo-Sa 05:00-11:00; PH off)", MONDAY_MORNING) == ["delivery"]
    assert active("delivery @ (Mo-Sa 05:00-11:00; PH off)", MONDAY_MORNING, holiday=True) == []


def test_vehicle_conditions_and_user_groups():
    heavy = parse("no @ (weight>7.5 AND 22:00-06:00)")[0]
    assert heavy.timed and heavy.applies_to(TRUCK) and not heavy.applies_to(VAN)
    assert parse("no @ (maxweightrating>7.5)")[0].applies_to(TRUCK)
    # "@ destination" to wyjątek dla dojazdu – nie dotyczy zwykłego przejazdu.
    assert not parse("none @ destination")[0].applies_to(TRUCK)
    assert not parse("none @ (agricultural, forestry)")[0].applies_to(TRUCK)


def test_unknown_conditions():
    assert parse("no @ (sunset-sunrise)") is None
    assert parse("no @ flooding") is None
    assert restrictive("no @ flooding")
    assert not restrictive("yes @ (Jul15 - Nov15)")


def test_conditional_tags_are_stored_whole():
    found = restrictions_from_tags({"highway": "primary", "hgv:conditional": "no @ (22:00-06:00)"})

    assert found == [(Kind.CONDITIONAL, None, "hgv:conditional=no @ (22:00-06:00)")]


LINE = [(17.0 + i * 0.005, 52.0) for i in range(50)]


def run(raw: str, vehicle=TRUCK, departure: datetime | None = None):
    edges = [
        RouteEdge(way_id=1, begin_index=10, end_index=20, road_class="primary", country="PL",
                  end_s=600.0)
    ]  # fmt: skip
    restriction = Restriction(osm_type="way", osm_id=1, kind="conditional", value=None, raw=raw)
    return analyze(LINE, edges, vehicle, {1: [restriction]}, [], departure)


def at(text: str) -> datetime:
    return datetime.fromisoformat(text).replace(tzinfo=timebans.HOME_ZONE)


def test_static_conditional_ban_is_red_for_heavy_vehicles_only():
    result = run("motor_vehicle:conditional=no @ (weight>7.5)")

    assert (result.level, result.warnings[0].message) == ("red", "Zakaz wjazdu (warunkowy)")
    assert run("motor_vehicle:conditional=no @ (weight>7.5)", VAN).level == "green"


def test_timed_ban_depends_on_departure():
    raw = "hgv:conditional=no @ (22:00-06:00)"

    night = run(raw, departure=at("2026-10-28T23:00"))
    assert night.level == "red"
    assert night.warnings[0].message == "Zakaz wjazdu ciężarówek (warunkowy) – (22:00-06:00)"
    assert run(raw, departure=at("2026-10-28T12:00")).level == "green"
    # Bez godziny wyjazdu ograniczenia czasowego nie da się ocenić – nie zgadujemy.
    assert run(raw).level == "green"


def test_timed_weight_limit_and_unknown_condition():
    weight = "maxweight:conditional=3.5 @ (Mo-Fr 07:00-19:00)"
    assert run(weight, departure=at("2026-10-28T08:00")).level == "red"
    assert run(weight, departure=at("2026-10-31T08:00")).level == "green"

    unknown = run("access:conditional=no @ winter")
    assert (unknown.level, unknown.warnings[0].message) == (
        "yellow",
        "Ograniczenie warunkowe – sprawdź znak (access:conditional=no @ winter)",
    )
    assert run("maxweight:conditional=none @ destination").warnings == []
