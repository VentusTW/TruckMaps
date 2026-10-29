import math

import pytest

from truckmaps.core.parkings import parking_kind
from truckmaps.core.restrictions import (
    Kind,
    Restriction,
    parse_length,
    parse_weight,
    restrictions_from_tags,
)
from truckmaps.core.route_analysis import RouteEdge, analyze
from truckmaps.core.vehicles import VehicleIn

TRUCK = VehicleIn(
    name="Zestaw",
    height_m=4.0,
    width_m=2.55,
    length_m=16.5,
    weight_t=40,
    axle_load_t=11.5,
    axle_count=5,
)
SOLO = VehicleIn(
    name="Solówka",
    height_m=3.5,
    width_m=2.55,
    length_m=9.5,
    weight_t=12,
    axle_load_t=8,
    axle_count=2,
)


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("3.8", 3.8),
        ("3,8 m", 3.8),
        ("380 cm", 3.8),
        ("12'6\"", 3.81),
        ("14'", 4.27),
        ("default", None),
        ("none", None),
        ("ok. 4", None),
    ],
)
def test_parse_length(raw, expected):
    assert parse_length(raw) == expected


@pytest.mark.parametrize(
    ("raw", "expected"),
    [("7.5", 7.5), ("7,5 t", 7.5), ("7500 kg", 7.5), ("10 st", 9.072), ("unsigned", None)],
)
def test_parse_weight(raw, expected):
    assert parse_weight(raw) == expected


def test_physical_height_wins_and_hgv_tags():
    found = restrictions_from_tags(
        {"maxheight": "4.2", "maxheight:physical": "4.05", "hgv": "destination"}
    )

    assert (Kind.HEIGHT, 4.05, "maxheight:physical=4.05;maxheight=4.2") in found
    assert len([f for f in found if f[0] is Kind.HEIGHT]) == 1
    assert (Kind.HGV_DESTINATION, None, "hgv=destination") in found


def straight_line(n: int = 50, step_deg: float = 0.0005) -> list[tuple[float, float]]:
    return [(17.0 + i * step_deg, 52.0) for i in range(n)]


def way_restriction(kind: Kind, value: float | None, raw: str, way_id: int = 1) -> Restriction:
    return Restriction(
        osm_type="way",
        osm_id=way_id,
        kind=kind.value,
        value=value,
        raw=raw,
        source="osm",
        source_date="2026-10-27",
    )


def run(vehicle, restrictions=(), nodes=(), points=None, edges=None):
    points = points or straight_line()
    edges = edges or [RouteEdge(way_id=1, begin_index=10, end_index=20, road_class="primary")]
    grouped = {}
    for r in restrictions:
        grouped.setdefault(r.osm_id, []).append(r)
    return analyze(points, edges, vehicle, grouped, list(nodes))


def test_clear_route_is_green():
    result = run(TRUCK)

    assert result.level == "green"
    assert result.warnings == []
    assert [s.level for s in result.segments] == ["green"]


@pytest.mark.parametrize(
    ("kind", "value", "level", "fragment"),
    [
        (Kind.HEIGHT, 3.8, "red", "pojazd 4 m"),
        (Kind.WEIGHT, 30, "red", "Ograniczenie masy rzeczywistej 30 t"),
        (Kind.WEIGHT_RATING, 18, "red", "Ograniczenie DMC 18 t, DMC pojazdu 40 t"),
        (Kind.AXLE_LOAD, 11.5, "green", None),
        (Kind.HEIGHT, 615, "green", None),  # błąd w danych OSM – pomijany
        (Kind.HGV_NO, None, "red", "Zakaz wjazdu"),
        (Kind.HGV_DESTINATION, None, "yellow", "tylko dojazd"),
    ],
)
def test_way_restrictions(kind, value, level, fragment):
    result = run(TRUCK, [way_restriction(kind, value, f"{kind}={value}")])

    assert result.level == level
    if fragment:
        assert fragment in result.warnings[0].message
        assert result.warnings[0].index == 10
        colored = [s for s in result.segments if s.level == level]
        assert (colored[0].start_index, colored[0].end_index) == (10, 20)


@pytest.mark.parametrize(
    ("raw", "level", "fragment"),
    [
        # Znak: dopuszczalna wartość – zestaw 4,0 m pod znakiem 4,0 m jedzie.
        ("maxheight=4", "green", None),
        ("maxheight=3.95", "red", "pojazd 4 m"),
        # Sam pomiar bez znaku: zapas poniżej 20 cm = pomarańczowy (omijany, z alternatywą).
        ("maxheight:physical=4", "orange", "zapas tylko 0 cm"),
        ("maxheight:physical=4.05", "orange", "zapas tylko 5 cm"),
        ("maxheight:physical=4.15", "orange", "zapas tylko 15 cm"),
        ("maxheight:physical=4.2", "green", None),
        ("maxheight:physical=3.9", "red", "pojazd 4 m"),
        # Znak i pomiar razem: znak dopuszcza 4 m, pomiar pokazuje 4,15 m – bez ostrzeżenia.
        ("maxheight:physical=4.15;maxheight=4", "green", None),
        # Znak dopuszcza 4,2 m, ale zmierzony prześwit jest niższy niż pojazd.
        ("maxheight:physical=3.95;maxheight=4.2", "red", "pojazd 4 m"),
        # Pojazd wyższy niż znak – nie może wjechać, nawet jeśli zmieściłby się pod pomiarem.
        ("maxheight:physical=4.05;maxheight=3.9", "red", "3,9 m (znak)"),
    ],
)
def test_height_sign_is_allowed_but_measured_clearance_needs_margin(raw, level, fragment):
    value = float(raw.split(";")[0].split("=")[1])
    result = run(TRUCK, [way_restriction(Kind.HEIGHT, value, raw)])

    assert result.level == level
    if fragment:
        assert fragment in result.warnings[0].message


def test_warning_carries_value_for_the_map_sign():
    result = run(TRUCK, [way_restriction(Kind.HEIGHT, 4.05, "maxheight:physical=4.05")])
    assert result.warnings[0].limit == "4,05 m"

    weight = run(TRUCK, [way_restriction(Kind.WEIGHT, 30, "maxweight=30")])
    assert weight.warnings[0].limit == "30 t"


def test_width_and_length_signs_are_allowed_up_to_the_limit():
    restrictions = [
        way_restriction(Kind.WIDTH, 2.55, "maxwidth=2.55"),
        way_restriction(Kind.LENGTH, 16.5, "maxlength=16.5"),
    ]
    assert run(TRUCK, restrictions).level == "green"

    physical = [way_restriction(Kind.WIDTH, 2.6, "maxwidth:physical=2.6")]
    assert run(TRUCK, physical).level == "orange"


def test_same_restriction_on_adjacent_edges_gives_one_warning():
    edges = [
        RouteEdge(way_id=1, begin_index=10, end_index=15),
        RouteEdge(way_id=1, begin_index=15, end_index=20),
    ]
    result = run(TRUCK, [way_restriction(Kind.HEIGHT, 4.1, "maxheight:physical=4.1")], edges=edges)

    assert len(result.warnings) == 1


def test_residential_street_level_depends_on_vehicle_length():
    edges = [
        RouteEdge(
            way_id=1,
            begin_index=10,
            end_index=20,
            road_class="residential",
            lane_count=1,
            names=["Długa"],
        )
    ]
    van = VehicleIn(
        name="Bus",
        height_m=2.8,
        width_m=2.0,
        length_m=6.5,
        weight_t=3.5,
        axle_load_t=2,
        axle_count=2,
    )

    truck = run(TRUCK, edges=edges)
    assert (truck.level, truck.warnings[0].message) == (
        "orange",
        "Ulica osiedlowa / dojazdowa – bardzo trudna dla zestawu (Długa)",
    )
    assert run(SOLO, edges=edges).level == "yellow"
    assert run(van, edges=edges).warnings == []


def test_roundabout_is_lime():
    edges = [RouteEdge(way_id=1, begin_index=10, end_index=20, roundabout=True, names=["Rondo"])]

    result = run(TRUCK, edges=edges)

    assert result.level == "lime"
    assert result.warnings[0].message == "Rondo (Rondo)"


def test_score_prefers_fewer_difficult_places():
    residential = [RouteEdge(way_id=1, begin_index=10, end_index=20, road_class="residential")]
    roundabout = [RouteEdge(way_id=1, begin_index=10, end_index=20, roundabout=True)]

    assert run(TRUCK, edges=roundabout).score < run(TRUCK, edges=residential).score
    assert run(TRUCK).score == 0


def arc_points(radius_m: float, degrees: float = 120) -> list[tuple[float, float]]:
    """Prosta – łuk o zadanym promieniu – prosta, w stopniach geograficznych."""
    m_lat, m_lon = 1 / 111_195, 1 / (111_195 * math.cos(math.radians(52)))
    points = [(17.0 + (i - 20) * 2 * m_lon, 52.0) for i in range(20)]
    for k in range(int(degrees / 5) + 1):
        angle = math.radians(k * 5)
        points.append(
            (
                17.0 + radius_m * math.sin(angle) * m_lon,
                52.0 + radius_m * (1 - math.cos(angle)) * m_lat,
            )
        )
    return points


def test_sharp_bend_depends_on_vehicle_length():
    points = arc_points(radius_m=10)
    edges = [RouteEdge(way_id=1, begin_index=0, end_index=len(points) - 1)]

    truck = run(TRUCK, points=points, edges=edges)
    assert [w.kind for w in truck.warnings] == ["bend"]
    assert "promień ok. 10 m" in truck.warnings[0].message
    assert truck.level == "yellow"

    assert run(SOLO, points=points, edges=edges).warnings == []


def test_very_sharp_bend_is_orange_for_long_vehicle():
    points = arc_points(radius_m=7)
    edges = [RouteEdge(way_id=1, begin_index=0, end_index=len(points) - 1)]

    result = run(TRUCK, points=points, edges=edges)

    assert result.level == "orange"
    assert result.warnings[0].message.startswith("Bardzo ostry zakręt")


def test_point_restriction_on_route_is_only_a_warning():
    points = straight_line()
    on_route = Restriction(
        osm_type="node",
        osm_id=9,
        kind="height",
        value=3.5,
        raw="maxheight=3.5",
        lat=52.0,
        lon=points[30][0] + 0.00001,
        source="osm",
        source_date="2026-10-27",
    )
    far_away = Restriction(
        osm_type="node",
        osm_id=10,
        kind="height",
        value=2.0,
        raw="maxheight=2",
        lat=52.001,
        lon=points[30][0],
        source="osm",
        source_date="2026-10-27",
    )

    result = run(TRUCK, nodes=[on_route, far_away])

    assert result.level == "yellow"
    assert len(result.warnings) == 1
    assert "punkt przy trasie" in result.warnings[0].message


RESIDENTIAL = [
    RouteEdge(way_id=1, begin_index=10, end_index=20, road_class="residential", names=["Chemiczna"])
]


@pytest.mark.parametrize(
    ("context", "level", "message"),
    [
        ([], "orange", "Ulica osiedlowa / dojazdowa – bardzo trudna dla zestawu (Chemiczna)"),
        (
            [(Kind.INDUSTRIAL_AREA, None)],
            "yellow",
            "Droga dojazdowa w strefie przemysłowej (Chemiczna)",
        ),
        ([(Kind.INDUSTRIAL_AREA, None), (Kind.ROAD_WIDTH, 3.5)], "orange", None),
        ([(Kind.ROAD_WIDTH, 7.0)], "green", None),
        ([(Kind.HGV_DESIGNATED, None)], "green", None),
    ],
    ids=["osiedle", "strefa-przemyslowa", "przemyslowa-ale-waska", "szeroka", "dla-ciezarowek"],
)
def test_minor_road_context_for_long_vehicle(context, level, message):
    restrictions = [way_restriction(kind, value, f"{kind}") for kind, value in context]

    result = run(TRUCK, restrictions, edges=RESIDENTIAL)

    assert result.level == level
    if message:
        assert result.warnings[0].message == message


def test_bad_surface_is_a_separate_yellow_warning():
    restrictions = [
        way_restriction(Kind.INDUSTRIAL_AREA, None, "landuse=industrial"),
        way_restriction(Kind.BAD_SURFACE, None, "smoothness=bad"),
    ]

    result = run(TRUCK, restrictions, edges=RESIDENTIAL)

    assert result.level == "yellow"
    assert sorted(w.message for w in result.warnings) == [
        "Droga dojazdowa w strefie przemysłowej (Chemiczna)",
        "Zła nawierzchnia (Chemiczna)",
    ]


def test_road_attributes_only_for_minor_roads():
    minor = restrictions_from_tags(
        {"highway": "residential", "width": "7", "smoothness": "bad", "hgv": "designated"}
    )
    assert {kind for kind, _, _ in minor} == {
        Kind.ROAD_WIDTH,
        Kind.BAD_SURFACE,
        Kind.HGV_DESIGNATED,
    }

    major = restrictions_from_tags({"highway": "primary", "width": "7", "smoothness": "bad"})
    assert major == []


@pytest.mark.parametrize(
    ("tags", "kind"),
    [
        ({"amenity": "parking", "hgv": "designated"}, "truck_parking"),
        ({"amenity": "parking", "capacity:hgv": "12"}, "truck_parking"),
        ({"amenity": "parking"}, None),
        ({"highway": "rest_area", "name": "MOP Komorów"}, "rest_area"),
        ({"highway": "rest_area", "name": "Miejsce Obsługi Rowerzystów"}, None),
        ({"highway": "services", "access": "private"}, None),
    ],
)
def test_parking_kind(tags, kind):
    assert parking_kind(tags) == kind


VAN = VehicleIn(
    name="Bus",
    height_m=2.7,
    width_m=2.0,
    length_m=6.0,
    weight_t=3.2,
    gvw_t=3.5,
    axle_load_t=2.0,
    axle_count=2,
)


@pytest.mark.parametrize("kind", [Kind.HGV_NO, Kind.HGV_DESTINATION])
def test_truck_bans_do_not_apply_up_to_3_5_t_gvw(kind):
    restriction = way_restriction(kind, None, str(kind))

    assert run(VAN, [restriction]).warnings == []
    assert run(TRUCK, [restriction]).warnings


def test_gvw_and_actual_weight_limits_are_separate():
    # Pusty zestaw: masa rzeczywista 15 t, DMC 40 t.
    empty = TRUCK.model_copy(update={"weight_t": 15.0, "gvw_t": 40.0})
    actual_limit = [way_restriction(Kind.WEIGHT, 20, "maxweight=20")]
    gvw_limit = [way_restriction(Kind.WEIGHT_RATING, 20, "maxweightrating=20")]

    assert run(empty, actual_limit).level == "green"
    assert run(empty, gvw_limit).level == "red"


def test_gvw_defaults_to_actual_weight_and_cannot_be_lower():
    assert VehicleIn(**{**TRUCK.model_dump(), "gvw_t": None}).gvw_t == 40
    with pytest.raises(ValueError, match="nie może być większa niż DMC"):
        VehicleIn(**{**TRUCK.model_dump(), "gvw_t": 30})
    assert restrictions_from_tags({"maxweightrating": "18"}) == [
        (Kind.WEIGHT_RATING, 18.0, "maxweightrating=18")
    ]
