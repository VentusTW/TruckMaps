import json

import httpx
import pytest
from fastapi.testclient import TestClient
from sqlalchemy.pool import StaticPool

from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.config import Settings
from truckmaps.core.db import Base, Database
from truckmaps.core.parkings import TruckParking
from truckmaps.core.restrictions import Restriction
from truckmaps.core.route_analysis import RouteEdge
from truckmaps.core.routing import (
    NoRouteFound,
    Point,
    Route,
    RoutingUnavailable,
    ValhallaRouter,
    decode_polyline6,
)
from truckmaps.core.vehicles import VehicleIn
from truckmaps.sdk import Principal

TRUCK = {
    "name": "Zestaw 40 t",
    "height_m": 4.0,
    "width_m": 2.55,
    "length_m": 16.5,
    "weight_t": 40,
    "axle_load_t": 11.5,
    "axle_count": 5,
    "trailer_type": "curtain",
}
POZNAN = {"lat": 52.4064, "lon": 16.9252}
WARSAW = {"lat": 52.2297, "lon": 21.0122}


class FakeVerifier:
    def verify(self, token: str) -> Principal:
        if not token.startswith("user-"):
            raise InvalidToken(token)
        return Principal(subject=token.removeprefix("user-"))


class FakeRouter:
    def __init__(
        self,
        error: Exception | None = None,
        edges: list[RouteEdge] | None = None,
        alternates: list[Route] = (),
    ):
        self.error = error
        self.edges = edges
        self.alternates = list(alternates)
        self.vehicles: list[VehicleIn] = []
        self.calls: list[tuple[list[Point], list[Point] | None]] = []

    def locate(self, stops, vehicle):
        return [(p, 0.0) for p in stops]

    def route(self, stops, vehicle: VehicleIn, exclude=None, alternates=0) -> Route:
        if self.error:
            raise self.error
        self.vehicles.append(vehicle)
        self.calls.append((stops, exclude))
        return Route(
            distance_km=310.4,
            duration_min=245.0,
            geometry=[(p.lon, p.lat) for p in stops],
            edges=self.edges,
            alternates=self.alternates if alternates else [],
        )


class DetourRouter:
    """Pierwsza trasa przez osiedle (pomarańczowy), po wykluczeniu – objazd drogą główną."""

    def __init__(self, detour_km: float = 12.0) -> None:
        self.detour_km = detour_km
        self.excluded: list[Point] | None = None

    def locate(self, stops, vehicle):
        return [(p, 0.0) for p in stops]

    def route(self, stops, vehicle: VehicleIn, exclude=None, alternates=0) -> Route:
        a, b = stops[0], stops[-1]
        geometry = [(a.lon + (b.lon - a.lon) * i / 100, a.lat) for i in range(101)]
        if exclude:
            self.excluded = exclude
            edges = [RouteEdge(way_id=1, begin_index=0, end_index=100, road_class="primary")]
            return Route(
                distance_km=self.detour_km, duration_min=15, geometry=geometry, edges=edges
            )
        edges = [
            RouteEdge(way_id=1, begin_index=0, end_index=40, road_class="primary"),
            RouteEdge(way_id=2, begin_index=40, end_index=60, road_class="residential"),
            RouteEdge(way_id=3, begin_index=60, end_index=100, road_class="primary"),
        ]
        return Route(distance_km=10.0, duration_min=12, geometry=geometry, edges=edges)


def as_user(subject: str) -> dict:
    return {"Authorization": f"Bearer user-{subject}"}


@pytest.fixture
def database() -> Database:
    database = Database(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(database.engine)
    return database


def make_client(database, router=None) -> TestClient:
    app = create_app(
        Settings(),
        modules=[],
        token_verifier=FakeVerifier(),
        database=database,
        router=router or FakeRouter(),
    )
    return TestClient(app)


def test_vehicle_crud_is_scoped_to_owner(database):
    client = make_client(database)

    created = client.post("/api/vehicles", json=TRUCK, headers=as_user("anna"))
    assert created.status_code == 201
    vehicle_id = created.json()["id"]

    assert [v["name"] for v in client.get("/api/vehicles", headers=as_user("anna")).json()] == [
        "Zestaw 40 t"
    ]
    assert client.get("/api/vehicles", headers=as_user("bob")).json() == []
    assert client.get(f"/api/vehicles/{vehicle_id}", headers=as_user("bob")).status_code == 404

    updated = client.put(
        f"/api/vehicles/{vehicle_id}", json=TRUCK | {"height_m": 3.8}, headers=as_user("anna")
    )
    assert updated.json()["height_m"] == 3.8

    assert client.delete(f"/api/vehicles/{vehicle_id}", headers=as_user("bob")).status_code == 404
    assert client.delete(f"/api/vehicles/{vehicle_id}", headers=as_user("anna")).status_code == 204
    assert client.get("/api/vehicles", headers=as_user("anna")).json() == []


def test_vehicle_requires_login_and_valid_dimensions(database):
    client = make_client(database)

    assert client.post("/api/vehicles", json=TRUCK).status_code == 401
    too_high = client.post("/api/vehicles", json=TRUCK | {"height_m": 40}, headers=as_user("a"))
    assert too_high.status_code == 422


def test_route_uses_owned_vehicle(database):
    router = FakeRouter()
    client = make_client(database, router)
    vehicle_id = client.post("/api/vehicles", json=TRUCK, headers=as_user("anna")).json()["id"]
    body = {"origin": POZNAN, "destination": WARSAW, "vehicle_id": vehicle_id}

    response = client.post("/api/routes", json=body, headers=as_user("anna"))

    assert response.status_code == 200
    assert response.json()["distance_km"] == 310.4
    assert response.json()["analysis"] is None  # router nie zwrócił odcinków
    assert "edges" not in response.json()
    assert router.vehicles[0].height_m == 4.0
    assert client.post("/api/routes", json=body, headers=as_user("bob")).status_code == 404


def test_route_analysis_uses_restrictions_from_database(database):
    with database.session() as db:
        db.add(
            Restriction(
                osm_type="way",
                osm_id=77,
                kind="height",
                value=3.8,
                raw="maxheight=3.8",
                source="osm",
                source_date="2026-10-27",
            )
        )
        db.commit()
    router = FakeRouter(edges=[RouteEdge(way_id=77, begin_index=0, end_index=1, names=["Mostowa"])])
    client = make_client(database, router)
    vehicle_id = client.post("/api/vehicles", json=TRUCK, headers=as_user("anna")).json()["id"]
    body = {"origin": POZNAN, "destination": WARSAW, "vehicle_id": vehicle_id}

    analysis = client.post("/api/routes", json=body, headers=as_user("anna")).json()["analysis"]

    assert analysis["level"] == "red"
    assert analysis["segments"] == [{"start_index": 0, "end_index": 1, "level": "red"}]
    assert analysis["warnings"][0]["message"] == (
        "Ograniczenie wysokości 3,8 m, pojazd 4 m (Mostowa)"
    )


@pytest.mark.parametrize(
    ("error", "status"), [(NoRouteFound("x"), 422), (RoutingUnavailable("x"), 503)]
)
def test_route_errors(database, error, status):
    client = make_client(database, FakeRouter(error))
    vehicle_id = client.post("/api/vehicles", json=TRUCK, headers=as_user("anna")).json()["id"]
    body = {"origin": POZNAN, "destination": WARSAW, "vehicle_id": vehicle_id}

    assert client.post("/api/routes", json=body, headers=as_user("anna")).status_code == status


def test_without_database_vehicles_are_unavailable():
    app = create_app(Settings(), modules=[], token_verifier=FakeVerifier())

    with TestClient(app) as client:
        assert client.get("/api/vehicles", headers=as_user("anna")).status_code == 503


def encode_polyline6(points: list[tuple[float, float]]) -> str:
    """Koduje [lon, lat] tak jak Valhalla – do budowania odpowiedzi w testach."""
    out, prev_lat, prev_lon = [], 0, 0
    for lon, lat in points:
        lat_i, lon_i = round(lat * 1e6), round(lon * 1e6)
        for delta in (lat_i - prev_lat, lon_i - prev_lon):
            value = ~(delta << 1) if delta < 0 else delta << 1
            while value >= 0x20:
                out.append(chr((0x20 | (value & 0x1F)) + 63))
                value >>= 5
            out.append(chr(value + 63))
        prev_lat, prev_lon = lat_i, lon_i
    return "".join(out)


def mock_client(handler) -> httpx.Client:
    return httpx.Client(transport=httpx.MockTransport(handler))


def assert_points(actual: list[tuple[float, float]], expected: list[tuple[float, float]]) -> None:
    """pytest.approx nie porównuje zagnieżdżonych list (od pytest 9.2), więc punkt po punkcie."""
    assert len(actual) == len(expected)
    for got, want in zip(actual, expected, strict=True):
        assert got == pytest.approx(want)


def test_decode_polyline6_round_trip():
    points = [(16.925200, 52.406400), (17.5, 52.3), (21.012200, 52.229700), (-3.7, -40.1)]

    assert_points(decode_polyline6(encode_polyline6(points)), points)


def test_valhalla_router_sends_truck_options():
    sent = {}
    shape = encode_polyline6([(16.9252, 52.4064), (21.0122, 52.2297)])

    def valhalla(request: httpx.Request) -> httpx.Response:
        sent.update(json.loads(request.content))
        trip = {"summary": {"length": 310.44, "time": 14700}, "legs": [{"shape": shape}]}
        return httpx.Response(200, json={"trip": trip})

    router = ValhallaRouter("http://valhalla.test", http=mock_client(valhalla))
    route = router.route([Point(**POZNAN), Point(**WARSAW)], VehicleIn(**TRUCK))

    assert sent["costing"] == "truck"
    assert sent["costing_options"]["truck"]["height"] == 4.0
    assert sent["costing_options"]["truck"]["weight"] == 40
    assert sent["costing_options"]["truck"]["axle_count"] == 5
    assert route.distance_km == 310.4
    assert route.duration_min == 245.0
    assert_points(route.geometry, [(16.9252, 52.4064), (21.0122, 52.2297)])


def test_valhalla_no_route_and_unavailable():
    def no_route(request):
        return httpx.Response(400, json={"error_code": 442, "error": "No path could be found"})

    def broken(request):
        raise httpx.ConnectError("refused")

    for handler, error in ((no_route, NoRouteFound), (broken, RoutingUnavailable)):
        router = ValhallaRouter("http://v.test", http=mock_client(handler))
        with pytest.raises(error):
            router.route([Point(**POZNAN), Point(**WARSAW)], VehicleIn(**TRUCK))


def test_valhalla_router_sends_via_points_and_exclusions():
    requests = {}
    shape = encode_polyline6([(16.9, 52.4), (21.0, 52.2)])

    def valhalla(request: httpx.Request) -> httpx.Response:
        requests[request.url.path] = json.loads(request.content)
        trip = {"summary": {"length": 1, "time": 60}, "legs": [{"shape": shape}]}
        return httpx.Response(200, json={"trip": trip, "edges": []})

    router = ValhallaRouter("http://valhalla.test", http=mock_client(valhalla))
    via = Point(lat=52.3, lon=19.0)
    avoid = Point(lat=52.35, lon=18.0)
    router.route([Point(**POZNAN), via, Point(**WARSAW)], VehicleIn(**TRUCK), exclude=[avoid])

    sent = requests["/route"]
    assert [loc["type"] for loc in sent["locations"]] == ["break", "through", "break"]
    assert sent["exclude_locations"] == [{"lat": 52.35, "lon": 18.0}]
    assert sent["costing_options"]["truck"]["use_living_streets"] == 0.0
    assert "edge.roundabout" in requests["/trace_attributes"]["filters"]["attributes"]


def test_edges_fall_back_to_map_snap_when_exact_match_fails():
    """Punkt pośredni w środku drogi: edge_walk zwraca 443, map_snap ma własną linię trasy."""
    route_shape = encode_polyline6([(16.90, 52.40), (17.00, 52.40), (17.10, 52.40)])
    snapped = [(16.90, 52.40), (16.95, 52.401), (17.00, 52.40), (17.10, 52.40)]
    matches = []

    def valhalla(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        if request.url.path == "/route":
            trip = {"summary": {"length": 14, "time": 900}, "legs": [{"shape": route_shape}]}
            return httpx.Response(200, json={"trip": trip})
        matches.append(body["shape_match"])
        if body["shape_match"] == "edge_walk":
            return httpx.Response(400, json={"error_code": 443, "error": "edge_walk failed"})
        edges = [
            {"way_id": 5, "begin_shape_index": 0, "end_shape_index": 3, "road_class": "primary"}
        ]
        return httpx.Response(200, json={"edges": edges, "shape": encode_polyline6(snapped)})

    router = ValhallaRouter("http://valhalla.test", http=mock_client(valhalla))
    route = router.route(
        [Point(**POZNAN), Point(lat=52.4, lon=17.0), Point(**WARSAW)], VehicleIn(**TRUCK)
    )

    assert matches == ["edge_walk", "map_snap"]
    assert [e.way_id for e in route.edges] == [5]
    assert_points(route.geometry, snapped)


def route_body(client, router_vehicle=TRUCK, **extra):
    vehicle_id = client.post("/api/vehicles", json=router_vehicle, headers=as_user("anna")).json()
    return {"origin": POZNAN, "destination": WARSAW, "vehicle_id": vehicle_id["id"], **extra}


def test_planner_avoids_orange_section_when_detour_is_reasonable(database):
    router = DetourRouter(detour_km=12.0)
    client = make_client(database, router)

    body = client.post("/api/routes", json=route_body(client), headers=as_user("anna")).json()

    assert body["distance_km"] == 12.0
    assert body["base_distance_km"] == 10.0
    assert body["analysis"]["level"] == "green"
    assert body["avoided"]
    assert router.excluded == [Point(**p) for p in body["avoided"]]
    # Najkrótsza trasa przez osiedle zostaje pokazana jako alternatywa.
    assert [(a["distance_km"], a["analysis"]["level"]) for a in body["alternatives"]] == [
        (10.0, "orange")
    ]


def test_alternatives_skip_duplicates_and_are_sorted_by_difficulty(database):
    def alternative(km: float, road_class: str) -> Route:
        edges = [RouteEdge(way_id=1, begin_index=0, end_index=1, road_class=road_class)]
        return Route(
            distance_km=km, duration_min=km, geometry=[(16.9, 52.4), (21.0, 52.2)], edges=edges
        )

    edges = [RouteEdge(way_id=1, begin_index=0, end_index=1, road_class="primary")]
    same_as_main = Route(
        distance_km=310.5, duration_min=245.2, geometry=[(16.9, 52.4)], edges=edges
    )
    router = FakeRouter(
        edges=edges,
        alternates=[
            same_as_main,
            alternative(330.0, "residential"),
            alternative(320.0, "primary"),
            alternative(420.0, "primary"),  # dużo dłuższa niż główna – pomijana
        ],
    )
    client = make_client(database, router)

    body = client.post("/api/routes", json=route_body(client), headers=as_user("anna")).json()

    assert [(a["distance_km"], a["analysis"]["level"]) for a in body["alternatives"]] == [
        (320.0, "green"),
        (330.0, "orange"),
    ]


def test_planner_keeps_route_when_detour_too_long_or_avoiding_disabled(database):
    client = make_client(database, DetourRouter(detour_km=50.0))
    too_long = client.post("/api/routes", json=route_body(client), headers=as_user("anna")).json()
    assert (too_long["distance_km"], too_long["analysis"]["level"]) == (10.0, "orange")

    router = DetourRouter(detour_km=12.0)
    client = make_client(database, router)
    body = route_body(client, avoid_difficult=False)
    disabled = client.post("/api/routes", json=body, headers=as_user("anna")).json()
    assert disabled["distance_km"] == 10.0
    assert router.excluded is None


def test_via_points_are_passed_in_order(database):
    router = FakeRouter()
    client = make_client(database, router)
    via = [{"lat": 52.3, "lon": 18.5}, {"lat": 52.25, "lon": 20.0}]

    client.post("/api/routes", json=route_body(client, via=via), headers=as_user("anna"))

    stops, _ = router.calls[0]
    assert [(p.lat, p.lon) for p in stops] == [
        (POZNAN["lat"], POZNAN["lon"]),
        (52.3, 18.5),
        (52.25, 20.0),
        (WARSAW["lat"], WARSAW["lon"]),
    ]


class UnreachableRouter(FakeRouter):
    """Punkty o podanych numerach są daleko od drogi dostępnej dla pojazdu."""

    def __init__(self, far: dict[int, float | None], **kwargs):
        super().__init__(**kwargs)
        self.far = far

    def locate(self, stops, vehicle):
        result = []
        for i, stop in enumerate(stops):
            if i not in self.far:
                result.append((stop, 0.0))
            elif self.far[i] is None:
                result.append(None)
            else:
                result.append((Point(lat=stop.lat + 0.001, lon=stop.lon), self.far[i]))
        return result


def add_parking(database, lat, lon, name, kind="truck_parking"):
    with database.session() as db:
        db.add(
            TruckParking(
                osm_type="node",
                osm_id=1,
                kind=kind,
                name=name,
                lat=lat,
                lon=lon,
                hgv_capacity=None,
                source="osm",
                source_date="2026-10-27",
            )
        )
        db.commit()


def test_unreachable_destination_shows_reachable_point_and_parkings(database):
    add_parking(database, WARSAW["lat"] + 0.01, WARSAW["lon"], "Parking TIR Wola")
    add_parking(database, 50.0, 19.0, "Daleko")
    client = make_client(database, UnreachableRouter(far={1: 120.0}))

    body = client.post("/api/routes", json=route_body(client), headers=as_user("anna")).json()

    (issue,) = body["stop_issues"]
    assert (issue["role"], issue["kind"], issue["distance_m"]) == (
        "destination",
        "unreachable",
        120.0,
    )
    assert "nie dojedzie do celu" in issue["message"]
    assert issue["reachable"]["lat"] == pytest.approx(WARSAW["lat"] + 0.001)
    assert [p["name"] for p in issue["parkings"]] == ["Parking TIR Wola"]


def test_unreachable_via_point_gets_message_without_parkings(database):
    client = make_client(database, UnreachableRouter(far={1: None}))
    body = route_body(client, via=[{"lat": 52.3, "lon": 18.5}])

    issue = client.post("/api/routes", json=body, headers=as_user("anna")).json()["stop_issues"][0]

    assert (issue["role"], issue["index"]) == ("via", 1)
    assert "Przez punkt pośredni nr 1 nie da się przejechać" in issue["message"]
    assert issue["reachable"] is None and issue["parkings"] == []


def test_points_close_to_road_are_fine(database):
    client = make_client(database, UnreachableRouter(far={0: 25.0}))

    body = client.post("/api/routes", json=route_body(client), headers=as_user("anna")).json()

    assert body["stop_issues"] == []


def test_no_route_error_explains_unreachable_point(database):
    router = UnreachableRouter(far={1: 300.0}, error=NoRouteFound("x"))
    client = make_client(database, router)

    response = client.post("/api/routes", json=route_body(client), headers=as_user("anna"))

    assert response.status_code == 422
    assert "nie dojedzie do celu" in response.json()["detail"]


def test_difficult_destination_suggests_parking(database):
    add_parking(database, WARSAW["lat"], WARSAW["lon"] + 0.01, "MOP Wschód", kind="rest_area")
    edges = [
        RouteEdge(way_id=1, begin_index=0, end_index=1, road_class="residential", names=["Rynek"])
    ]
    router = FakeRouter(edges=edges)
    router.route = _short_route(router.route)
    client = make_client(database, router)

    issues = client.post("/api/routes", json=route_body(client), headers=as_user("anna")).json()[
        "stop_issues"
    ]

    roles = {issue["role"]: issue for issue in issues}
    assert roles["destination"]["kind"] == "difficult"
    assert "Trudny dojazd do celu" in roles["destination"]["message"]
    assert roles["destination"]["parkings"][0]["name"] == "MOP Wschód"


def _short_route(route):
    """Krótka trasa (200 m), żeby trudne miejsce było przy samym celu."""

    def wrapper(stops, vehicle, exclude=None, alternates=0):
        result = route(stops, vehicle, exclude, alternates)
        return result.model_copy(update={"distance_km": 0.2})

    return wrapper
