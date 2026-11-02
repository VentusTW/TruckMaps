from fastapi.testclient import TestClient

from truckmaps.core import reports
from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.config import Settings
from truckmaps.core.route_analysis import RouteEdge
from truckmaps.core.routing import NoRouteFound, Route
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


# Prosto przez ulicę z ograniczeniem (droga OSM 2) albo objazdem (droga 3).
STREET_POINT = {"lat": 52.30, "lon": 19.0}


class StreetRouter(FakeRouter):
    """Trasa przez ulicę ``2``; z wykluczeniami – objazd drogą ``3`` (gdy ``detour``)."""

    def __init__(self, detour=True):
        self.detour = detour
        self.located = []

    def streets_near(self, points, radius_m):
        self.located += points
        return [[(2, "Ostrogskich", 3.0), (5, "Tuchowska", 30.0)] for _ in points]

    def route(self, stops, vehicle, exclude=None, alternates=0) -> Route:
        start, end = (stops[0].lon, stops[0].lat), (stops[-1].lon, stops[-1].lat)
        if exclude and not self.detour:
            raise NoRouteFound
        way, middle, km = (3, (19.0, 52.6), 330.0) if exclude else (2, (19.0, 52.3), 310.4)
        geometry = [start, middle, end]
        edges = [
            RouteEdge(way_id=1, begin_index=0, end_index=1, road_class="primary"),
            RouteEdge(way_id=way, begin_index=1, end_index=2, road_class="primary"),
        ]
        return Route(distance_km=km, duration_min=245.0, geometry=geometry, edges=edges)


def plan_route(client, user="anna"):
    headers = as_user(user)
    vehicle_id = client.post("/api/vehicles", json=TRUCK, headers=headers).json()["id"]
    body = {"origin": POZNAN, "destination": WARSAW, "vehicle_id": vehicle_id}
    return client.post("/api/routes", json=body, headers=headers)


WEIGHT_3_5 = {"kind": "weight_limit", "value": 3.5, **STREET_POINT}


def test_reported_weight_limit_is_always_avoided_and_shown_as_sign(database):
    router = StreetRouter()
    client = make_client(database, router)
    client.post("/api/reports", json=WEIGHT_3_5, headers=as_user("anna"))

    route = plan_route(client).json()

    assert route["distance_km"] == 330.0  # objazd, mimo że dłuższy
    (avoided,) = route["avoided_warnings"]
    assert (avoided["kind"], avoided["level"], avoided["limit"]) == ("reported", "orange", "3,5 t")
    assert "zgłoszenie innych kierowców" in avoided["message"]
    assert router.located == [(19.0, 52.30)]  # droga przypisana raz, przy pierwszej trasie
    plan_route(client, "bob")
    assert router.located == [(19.0, 52.30)]


def test_unconfirmed_report_without_detour_stays_a_warning(database):
    client = make_client(database, StreetRouter(detour=False))
    client.post("/api/reports", json=WEIGHT_3_5, headers=as_user("anna"))

    route = plan_route(client).json()

    assert route["distance_km"] == 310.4
    assert [(w["kind"], w["level"]) for w in route["analysis"]["warnings"]] == [
        ("reported", "orange")
    ]


def test_limit_confirmed_by_several_drivers_is_permanent(database):
    client = make_client(database, StreetRouter(detour=False))
    for user in ("anna", "bob", "celina"):
        report = client.post("/api/reports", json=WEIGHT_3_5, headers=as_user(user)).json()
    assert (report["score"], report["permanent"]) == (3, True)

    # Na stałe – jak dane z mapy: zestaw 40 t nie przejedzie, a objazdu nie ma.
    response = plan_route(client)
    assert response.status_code == 422
    assert "potwierdzone przez kierowców (3)" in response.json()["detail"]

    # Lekki pojazd (inny kierowca) jedzie dalej.
    light = TRUCK | {"name": "Bus", "weight_t": 3.0, "gvw_t": 3.5, "height_m": 2.8}
    headers = as_user("dawid")
    vehicle_id = client.post("/api/vehicles", json=light, headers=headers).json()["id"]
    body = {"origin": POZNAN, "destination": WARSAW, "vehicle_id": vehicle_id}
    assert client.post("/api/routes", json=body, headers=headers).status_code == 200


def test_street_choice_when_report_is_at_a_junction(database):
    class JunctionRouter(StreetRouter):
        def streets_near(self, points, radius_m):
            self.located += points
            return [[(5, "Tuchowska", 5.3), (2, "Ostrogskich", 11.6), (6, "Tuchowska", 16.6)]]

    router = JunctionRouter()
    client = make_client(database, router)
    anna = as_user("anna")

    streets = client.get("/api/reports/streets", params=STREET_POINT, headers=anna).json()
    assert [(s["way_id"], s["name"]) for s in streets] == [(5, "Tuchowska"), (2, "Ostrogskich")]

    # Bez wyboru ulicy przy skrzyżowaniu zgłoszenie nie blokuje żadnej drogi (to może być główna).
    client.post("/api/reports", json=WEIGHT_3_5, headers=anna)
    assert plan_route(client).json()["distance_km"] == 310.4

    # Kierowca wybrał Ostrogskich – objazd.
    client.post("/api/reports", json=WEIGHT_3_5 | {"lat": 52.31, "way_id": 2}, headers=anna)
    assert plan_route(client, "bob").json()["distance_km"] == 330.0
