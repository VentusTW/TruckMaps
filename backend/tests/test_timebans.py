from datetime import date, datetime, timedelta

import pytest

from truckmaps.core import timebans
from truckmaps.core.i18n import t
from truckmaps.core.route_analysis import RouteEdge
from truckmaps.core.routing import Route
from truckmaps.core.timebans import (
    applies,
    check_route,
    de_holidays,
    easter,
    pl_summer,
    windows,
)
from truckmaps.core.vehicles import VehicleIn

TRUCK = VehicleIn(
    name="Zestaw", height_m=4, width_m=2.55, length_m=16.5, weight_t=40, axle_load_t=11.5,
    axle_count=5,
)  # fmt: skip
SOLO_10T = VehicleIn(
    name="Solówka 10 t", height_m=3.5, width_m=2.55, length_m=8, weight_t=10, axle_load_t=7,
    axle_count=2, trailer_type="none",
)  # fmt: skip
WARSAW = timebans.ZONES["PL"]


def local(text: str, zone=WARSAW) -> datetime:
    return datetime.fromisoformat(text).replace(tzinfo=zone)


@pytest.mark.parametrize(
    ("year", "expected"),
    [(2024, date(2024, 3, 31)), (2025, date(2025, 4, 20)), (2026, date(2026, 4, 5))],
)
def test_easter(year, expected):
    assert easter(year) == expected


@pytest.mark.parametrize(
    ("year", "expected"),
    [
        (2026, (date(2026, 6, 26), date(2026, 8, 30))),
        # Zajęcia do piątku 21.06; 1.09 to niedziela – szkoła od poniedziałku 2.09.
        (2024, (date(2024, 6, 21), date(2024, 9, 1))),
        # 1.09 w piątek – szkoła od poniedziałku 4.09, ostatnia niedziela wakacji 3.09.
        (2023, (date(2023, 6, 23), date(2023, 9, 3))),
    ],
)
def test_polish_summer_holidays(year, expected):
    assert pl_summer(year) == expected


def titles(country, day, state=""):
    return [(t(w.title), w.start.hour, w.end.hour) for w in windows(country, day, state)]


def test_polish_bans():
    assert titles("PL", date(2026, 11, 1)) == [("święto (Wszystkich Świętych)", 8, 22)]
    assert titles("PL", date(2026, 10, 31)) == [
        ("dzień przed świętem (Wszystkich Świętych)", 18, 22)
    ]
    # Zwykła niedziela poza wakacjami – w Polsce bez zakazu; przed Nowym Rokiem też.
    assert titles("PL", date(2026, 10, 25)) == []
    assert titles("PL", date(2026, 12, 31)) == []
    assert titles("PL", date(2026, 7, 4)) == [("wakacje – sobota", 8, 14)]
    assert titles("PL", date(2026, 8, 15)) == [("święto (Wniebowzięcie NMP)", 8, 22)]


def test_german_bans_with_regional_holidays():
    assert titles("DE", date(2026, 10, 25)) == [("niedziela", 0, 22)]
    assert titles("DE", date(2026, 10, 31), "SN") == [("święto (Reformationstag)", 0, 22)]
    assert titles("DE", date(2026, 10, 31), "BY") == []
    assert "Allerheiligen" in de_holidays(2026, "BY").values()
    summer = windows("DE", date(2026, 7, 4))
    assert (summer[0].refs, summer[0].verified) == (timebans.DE_SUMMER_ROADS, False)


def test_czech_and_slovak_bans_only_on_main_roads():
    assert titles("CZ", date(2026, 10, 25)) == [("niedziela", 13, 22)]
    assert titles("CZ", date(2026, 7, 3)) == [("wakacje – piątek", 17, 21)]
    assert windows("CZ", date(2026, 10, 25))[0].roads == timebans.MAIN_ROADS
    assert titles("SK", date(2026, 8, 29)) == [("święto (Výročie SNP)", 0, 22)]
    assert titles("LT", date(2026, 10, 25)) == []


def test_which_vehicles_are_banned():
    assert applies("PL", TRUCK) and applies("DE", TRUCK) and applies("CZ", TRUCK)
    # Solówka 10 t: w Polsce zakaz od 12 t, w Niemczech i Czechach od 7,5 t.
    assert not applies("PL", SOLO_10T)
    assert applies("DE", SOLO_10T)
    assert not applies("LT", TRUCK)


def route_through(*parts: tuple[str, str, str, float]) -> Route:
    """Trasa z odcinków (kraj, region, klasa drogi, czas jazdy w h) po 10 punktów linii."""
    geometry, edges, elapsed = [], [], 0.0
    for country, state, road_class, hours in parts:
        begin = len(geometry) - 1 if geometry else 0
        geometry += [(15.0 + 0.01 * i, 51.0) for i in range(len(geometry), begin + 11)]
        elapsed += hours * 3600
        edges.append(
            RouteEdge(
                way_id=len(edges) + 1, begin_index=begin, end_index=len(geometry) - 1,
                road_class=road_class, country=country, state=state, end_s=elapsed,
            )
        )  # fmt: skip
    return Route(distance_km=100, duration_min=elapsed / 60, geometry=geometry, edges=edges)


def test_vehicle_waits_for_ban_and_later_times_shift():
    # Sobota 31.10: 2 h w Polsce, potem 2 h w Saksonii (Reformationstag), potem Czechy.
    route = route_through(
        ("PL", "", "motorway", 2), ("DE", "SN", "motorway", 2), ("CZ", "", "motorway", 1)
    )

    result = check_route(route, TRUCK, local("2026-10-31T15:00"))

    # 17:00 wjazd do DE w czasie święta → postój do 22:00, potem Czechy w nocy (bez zakazu).
    assert [(b.country, b.title, b.wait_min) for b in result.bans] == [
        ("DE", "święto (Reformationstag)", 300)
    ]
    assert result.bans[0].parkings == []
    assert result.wait_min == 300
    assert result.arrival == local("2026-11-01T01:00")
    # Wcześniej się nie da: w sobotę 18–22 zakaz w Polsce, w niedzielę do 22:00 w Niemczech.
    assert result.free_departure == local("2026-11-01T22:00")


def test_ban_on_main_roads_does_not_apply_to_local_roads():
    route = route_through(("CZ", "", "secondary", 1), ("CZ", "", "primary", 1))

    result = check_route(route, TRUCK, local("2026-10-25T12:30", timebans.ZONES["CZ"]))

    assert [(b.title, b.km > 0) for b in result.bans] == [("niedziela", True)]
    assert "Postój do niedz. 25.10 22:00" in result.bans[0].message


def test_uncertain_ban_is_a_warning_without_waiting():
    route = route_through(("DE", "BY", "motorway", 1))
    route.edges[0].names = ["A 9", "E 51"]

    result = check_route(route, TRUCK, local("2026-07-04T10:00"))

    assert [(b.verified, b.wait_min) for b in result.bans] == [(False, 600)]
    assert "Sprawdź" in result.bans[0].message
    assert (result.wait_min, result.free_departure) == (0, None)


def test_no_bans_on_a_working_day():
    route = route_through(("PL", "", "motorway", 3), ("DE", "BB", "motorway", 3))

    result = check_route(route, TRUCK, local("2026-10-28T08:00"))

    assert (result.bans, result.wait_min) == ([], 0)
    assert result.arrival - local("2026-10-28T08:00") == timedelta(hours=6)
