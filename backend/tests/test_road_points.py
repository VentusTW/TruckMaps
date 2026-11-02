from sqlalchemy.pool import StaticPool

from truckmaps.core.db import Base, Database
from truckmaps.core.polyline import encode_polyline6
from truckmaps.core.road_points import PointKind, RoadPoint, along_route, parse_speed
from truckmaps.core.route_analysis import RouteEdge
from truckmaps.core.routing import _lanes, _maneuvers, speed_limits
from truckmaps.core.vehicles import VehicleIn

# Prosta trasa na wschód wzdłuż równoleżnika 50°: 0,01° długości ≈ 715 m.
ROUTE = [(20.0 + i * 0.001, 50.0) for i in range(41)]


def row(kind, lon, lat, **extra):
    points = [(lon, lat), *extra.pop("more", [])]
    return RoadPoint(
        osm_type="node", osm_id=1, kind=kind, lat=lat, lon=lon,
        min_lat=min(p[1] for p in points), max_lat=max(p[1] for p in points),
        min_lon=min(p[0] for p in points), max_lon=max(p[0] for p in points),
        source="osm", source_date="2026-11-01", **extra,
    )  # fmt: skip


def test_points_and_sections_along_route():
    database = Database(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(database.engine)
    no_overtaking = [(20.010, 50.0), (20.015, 50.0)]
    with database.session() as db:
        db.add_all(
            [
                row(PointKind.LEVEL_CROSSING, 20.005, 50.0001),
                row(PointKind.SPEED_CAMERA, 20.02, 50.0, value=70),
                row(PointKind.TRAFFIC_SIGNALS, 20.03, 50.0005),  # 55 m obok – inna droga
                row(
                    PointKind.AVERAGE_SPEED,
                    20.022,
                    50.0,
                    end_lon=20.03,
                    end_lat=50.0,
                    value=80,
                    more=[(20.03, 50.0)],
                ),  # fmt: skip
                row(
                    PointKind.NO_OVERTAKING,
                    *no_overtaking[0],
                    line=encode_polyline6(no_overtaking),
                    more=no_overtaking[1:],
                ),  # fmt: skip
                row(PointKind.SPEED_CAMERA, 21.0, 51.0),  # daleko
            ]
        )
        db.commit()
        events = along_route(db, ROUTE)
    kinds = [e.kind for e in events]
    assert kinds == ["level_crossing", "no_overtaking", "speed_camera", "average_speed"]
    assert abs(events[0].km - 0.358) < 0.02
    assert events[1].end_km and abs(events[1].end_km - events[1].km - 0.358) < 0.02
    assert events[2].speed_kmh == 70
    assert events[3].end_km and events[3].end_km > events[3].km


def test_parse_speed():
    assert [parse_speed(v) for v in ("70", "50 km/h", "30 mph", "signals", None)] == [
        70,
        50,
        48,
        None,
        None,
    ]


def test_speed_limits_cap_trucks_in_poland_and_merge():
    truck = VehicleIn(
        name="T",
        axle_count=5,
        height_m=4,
        width_m=2.55,
        length_m=16.5,
        weight_t=40,
        axle_load_t=11.5,
    )
    edges = [
        RouteEdge(way_id=1, begin_index=0, end_index=3, road_class="motorway", country="PL",
                  speed_limit=140),
        RouteEdge(way_id=2, begin_index=3, end_index=5, road_class="motorway", country="PL"),
        RouteEdge(way_id=3, begin_index=5, end_index=8, road_class="primary", country="PL",
                  speed_limit=90),
        RouteEdge(way_id=4, begin_index=8, end_index=9, road_class="residential", country="PL"),
        RouteEdge(way_id=5, begin_index=9, end_index=12, road_class="primary", country="CZ",
                  speed_limit=90),
    ]  # fmt: skip
    limits = [(s.start_index, s.end_index, s.kmh, s.posted) for s in speed_limits(edges, truck)]
    assert limits == [(0, 3, 80, 140), (3, 5, 80, None), (5, 8, 70, 90), (9, 12, 90, 90)]
    van = VehicleIn(
        name="V", axle_count=2, height_m=2.5, width_m=2, length_m=6, weight_t=3.5, axle_load_t=2
    )
    assert speed_limits(edges[:1], van)[0].kmh == 140


def test_maneuver_signs_roundabout_and_lanes():
    leg = {
        "shape": encode_polyline6([(20.0, 50.0), (20.01, 50.0)]),
        "maneuvers": [
            {"type": 26, "instruction": "Wjedź na rondo", "roundabout_exit_count": 3,
             "length": 1.0, "begin_shape_index": 0},
            {"type": 20, "instruction": "Zjedź", "length": 2.0, "begin_shape_index": 1,
             "sign": {"exit_number_elements": [{"text": "42"}],
                      "exit_toward_elements": [{"text": "Oświęcim"}, {"text": "Kraków"}],
                      "exit_branch_elements": [{"text": "A4"}]},
             "lanes": [{"directions": 8}, {"directions": 2 | 64, "active": 64}]},
        ],
    }  # fmt: skip
    first, second = _maneuvers(leg, 0.0)
    assert first.roundabout_exit == 3
    assert (second.exit_number, second.toward, second.branch) == (
        "42",
        ["Oświęcim", "Kraków"],
        ["A4"],
    )
    assert [(lane.directions, lane.active) for lane in second.lanes] == [
        (["left"], False),
        (["through", "right"], True),
    ]
    assert _lanes(None) == []
