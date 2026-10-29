from fastapi.testclient import TestClient

from truckmaps.core import reports
from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.config import Settings
from truckmaps.core.routing import Route
from truckmaps.sdk import Principal

TRUCK = {
    "name": "Zestaw 40 t",
    "height_m": 4.0,
    "width_m": 2.55,
    "length_m": 16.5,
    "weight_t": 40,
    "axle_load_t": 11.5,
    "axle_count": 5,
}
POZNAN = {"lat": 52.4064, "lon": 16.9252}
WARSAW = {"lat": 52.2297, "lon": 21.0122}


class FakeVerifier:
    def verify(self, token: str) -> Principal:
        if not token.startswith("user-"):
            raise InvalidToken(token)
        return Principal(subject=token.removeprefix("user-"))


class FakeRouter:
    """Trasa w linii prostej przez punkty."""

    def locate(self, stops, vehicle):
        return [(p, 0.0) for p in stops]

    def route(self, stops, vehicle, exclude=None, alternates=0) -> Route:
        geometry = [(p.lon, p.lat) for p in stops]
        return Route(distance_km=310.4, duration_min=245.0, geometry=geometry)


def as_user(subject: str) -> dict:
    return {"Authorization": f"Bearer user-{subject}"}


def make_client(database, router=None) -> TestClient:
    app = create_app(
        Settings(),
        modules=[],
        token_verifier=FakeVerifier(),
        database=database,
        router=router or FakeRouter(),
    )
    return TestClient(app)


RAMP = {"kind": "ramp", "lat": 52.2300, "lon": 21.0125}  # ok. 40 m od celu (WARSAW)


def test_report_one_tap_and_confirmation_by_other_driver(database):
    client = make_client(database)

    created = client.post("/api/reports", json=RAMP, headers=as_user("anna"))
    assert created.status_code == 201
    report = created.json()
    assert (report["label"], report["score"], report["mine"]) == ("Rampa", 1, True)

    # To samo miejsce i rodzaj od innego kierowcy = potwierdzenie, nie drugie zgłoszenie.
    again = client.post("/api/reports", json=RAMP | {"lat": 52.23005}, headers=as_user("bob"))
    assert (again.status_code, again.json()["id"], again.json()["score"]) == (200, report["id"], 2)
    assert again.json()["mine"] is False

    nearby = client.get(
        "/api/reports", params={"lat": 52.2297, "lon": 21.0122}, headers=as_user("bob")
    ).json()
    assert [(r["kind"], r["distance_m"]) for r in nearby] == [("ramp", 39)]


def test_reports_need_details_and_texts_follow_language(database):
    client = make_client(database)
    english = as_user("anna") | {"Accept-Language": "en"}

    no_hours = client.post("/api/reports", json=RAMP | {"kind": "hours"}, headers=as_user("anna"))
    assert no_hours.status_code == 422
    assert "godziny przyjęć" in no_hours.text
    no_value = client.post("/api/reports", json=RAMP | {"kind": "height_limit"}, headers=english)
    assert "value from the sign" in no_value.text

    hours = RAMP | {"kind": "hours", "note": "pn–pt 6–14"}
    assert client.post("/api/reports", json=hours, headers=as_user("anna")).json()["message"] == (
        "Godziny przyjęć: pn–pt 6–14"
    )
    height = RAMP | {"kind": "height_limit", "value": 3.5}
    assert client.post("/api/reports", json=height, headers=english).json()["message"] == (
        "Height limit 3.5 m"
    )


def test_outdated_votes_hide_report_and_only_author_deletes(database):
    client = make_client(database)
    report_id = client.post("/api/reports", json=RAMP, headers=as_user("anna")).json()["id"]

    own = client.post(f"/api/reports/{report_id}/vote", json={"up": False}, headers=as_user("anna"))
    assert own.status_code == 409
    for voter in ("bob", "carl", "dora"):
        client.post(f"/api/reports/{report_id}/vote", json={"up": False}, headers=as_user(voter))
    # Zmiana zdania zastępuje głos, nie dodaje drugiego.
    vote = client.post(f"/api/reports/{report_id}/vote", json={"up": True}, headers=as_user("bob"))
    assert vote.json()["score"] == 0
    client.post(f"/api/reports/{report_id}/vote", json={"up": False}, headers=as_user("bob"))

    params = {"lat": 52.2297, "lon": 21.0122}
    assert client.get("/api/reports", params=params, headers=as_user("bob")).json() == []
    assert client.delete(f"/api/reports/{report_id}", headers=as_user("bob")).status_code == 403
    assert client.delete(f"/api/reports/{report_id}", headers=as_user("anna")).status_code == 204
    assert client.get("/api/reports/mine", headers=as_user("anna")).json() == []


def test_route_shows_delivery_points_at_destination_and_road_reports_on_route(database):
    client = make_client(database, FakeRouter())
    anna = as_user("anna")
    client.post("/api/reports", json=RAMP, headers=anna)
    gate_at_start = RAMP | {"kind": "gate", "lat": 52.40, "lon": 16.93}
    client.post("/api/reports", json=gate_at_start, headers=anna)
    # Na linii Poznań – Warszawa (prosta w FakeRouter), mniej więcej w połowie.
    middle = {key: (POZNAN[key] + WARSAW[key]) / 2 for key in ("lat", "lon")}
    client.post("/api/reports", json={"kind": "road_closed", **middle}, headers=anna)
    client.post("/api/reports", json={"kind": "narrow", "lat": 50.0, "lon": 19.0}, headers=anna)
    vehicle_id = client.post("/api/vehicles", json=TRUCK, headers=anna).json()["id"]

    body = {"origin": POZNAN, "destination": WARSAW, "vehicle_id": vehicle_id}
    route = client.post("/api/routes", json=body, headers=as_user("anna")).json()

    assert [(p["kind"], p["distance_m"]) for p in route["destination_points"]] == [("ramp", 39)]
    assert [r["kind"] for r in route["driver_reports"]] == ["road_closed"]
    assert route["driver_reports"][0]["km"] > 100


def test_daily_limit(database, monkeypatch):
    monkeypatch.setattr(reports, "DAILY_LIMIT", 2)
    client = make_client(database)

    for i in range(2):
        point = RAMP | {"lat": 52.0 + i / 100}
        assert client.post("/api/reports", json=point, headers=as_user("anna")).status_code == 201
    assert client.post("/api/reports", json=RAMP, headers=as_user("anna")).status_code == 429
