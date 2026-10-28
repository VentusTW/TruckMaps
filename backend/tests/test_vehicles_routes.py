import json

import httpx
import pytest
from fastapi.testclient import TestClient
from sqlalchemy.pool import StaticPool

from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.config import Settings
from truckmaps.core.db import Base, Database
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
    def __init__(self, error: Exception | None = None) -> None:
        self.error = error
        self.vehicles: list[VehicleIn] = []

    def route(self, origin: Point, destination: Point, vehicle: VehicleIn) -> Route:
        if self.error:
            raise self.error
        self.vehicles.append(vehicle)
        return Route(
            distance_km=310.4,
            duration_min=245.0,
            geometry=[(origin.lon, origin.lat), (destination.lon, destination.lat)],
        )


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
    assert router.vehicles[0].height_m == 4.0
    assert client.post("/api/routes", json=body, headers=as_user("bob")).status_code == 404


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


def test_decode_polyline6_round_trip():
    points = [(16.925200, 52.406400), (17.5, 52.3), (21.012200, 52.229700), (-3.7, -40.1)]

    assert decode_polyline6(encode_polyline6(points)) == pytest.approx(points)


def test_valhalla_router_sends_truck_options():
    sent = {}
    shape = encode_polyline6([(16.9252, 52.4064), (21.0122, 52.2297)])

    def valhalla(request: httpx.Request) -> httpx.Response:
        sent.update(json.loads(request.content))
        trip = {"summary": {"length": 310.44, "time": 14700}, "legs": [{"shape": shape}]}
        return httpx.Response(200, json={"trip": trip})

    router = ValhallaRouter("http://valhalla.test", http=mock_client(valhalla))
    route = router.route(Point(**POZNAN), Point(**WARSAW), VehicleIn(**TRUCK))

    assert sent["costing"] == "truck"
    assert sent["costing_options"]["truck"]["height"] == 4.0
    assert sent["costing_options"]["truck"]["weight"] == 40
    assert sent["costing_options"]["truck"]["axle_count"] == 5
    assert route.distance_km == 310.4
    assert route.duration_min == 245.0
    assert route.geometry == pytest.approx([(16.9252, 52.4064), (21.0122, 52.2297)])


def test_valhalla_no_route_and_unavailable():
    def no_route(request):
        return httpx.Response(400, json={"error_code": 442, "error": "No path could be found"})

    def broken(request):
        raise httpx.ConnectError("refused")

    for handler, error in ((no_route, NoRouteFound), (broken, RoutingUnavailable)):
        router = ValhallaRouter("http://v.test", http=mock_client(handler))
        with pytest.raises(error):
            router.route(Point(**POZNAN), Point(**WARSAW), VehicleIn(**TRUCK))
