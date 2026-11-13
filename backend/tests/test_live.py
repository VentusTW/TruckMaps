from datetime import timedelta

import pytest
from fastapi.testclient import TestClient

from truckmaps.core import live
from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.config import Settings
from truckmaps.sdk import Principal

COMPANY = {"name": "Trans-Test"}
TRUCK = {
    "name": "MAN 01",
    "plate": "KR 1234A",
    "height_m": 4.0,
    "width_m": 2.55,
    "length_m": 16.5,
    "weight_t": 40,
    "axle_load_t": 11.5,
    "axle_count": 5,
    "trailer_type": "curtain",
}


class FakeVerifier:
    def verify(self, token: str) -> Principal:
        kind, _, subject = token.partition("-")
        if kind != "user" or not subject:
            raise InvalidToken(token)
        return Principal(subject=subject, claims={})


def as_user(subject: str) -> dict:
    return {"Authorization": f"Bearer user-{subject}"}


@pytest.fixture
def client(database):
    return TestClient(
        create_app(
            Settings(dev_grant_all=True),
            modules=[],
            token_verifier=FakeVerifier(),
            database=database,
        )
    )


def join(client, company_id: str, who: str, role: str) -> None:
    code = client.post(
        f"/api/companies/{company_id}/invites", json={"role": role}, headers=as_user("owner")
    ).json()["code"]
    assert (
        client.post(f"/api/invites/{code}/accept", json={}, headers=as_user(who)).status_code == 200
    )


def test_driver_position_shown_to_dispatcher_and_goes_stale(client, database):
    company = client.post("/api/companies", json=COMPANY, headers=as_user("owner")).json()["id"]
    join(client, company, "jan", "driver")
    join(client, company, "ewa", "dispatcher")
    truck = client.post(
        "/api/vehicles", json=TRUCK | {"company_id": company}, headers=as_user("owner")
    ).json()["id"]
    trailer = TRUCK | {"name": "Naczepa", "kind": "semitrailer", "company_id": company}
    client.post("/api/vehicles", json=trailer, headers=as_user("owner"))

    # Przed pierwszą pozycją: pojazd na liście, bez sygnału; naczep nie ma.
    (empty,) = client.get(f"/api/companies/{company}/live", headers=as_user("ewa")).json()
    assert (empty["name"], empty["state"], empty["lat"]) == ("MAN 01", "no_signal", None)

    position = {"lat": 50.06, "lon": 19.94, "speed_kmh": 72.5, "heading": 90, "destination": "Lyon"}
    sent = client.post(f"/api/vehicles/{truck}/position", json=position, headers=as_user("jan"))
    assert sent.status_code == 204

    (seen,) = client.get(f"/api/companies/{company}/live", headers=as_user("ewa")).json()
    assert (seen["state"], seen["speed_kmh"], seen["destination"]) == ("driving", 72.5, "Lyon")
    assert seen["driver"].endswith("jan")  # nazwa członka firmy
    # Kierowca nie widzi centrali, obcy nie może wysłać pozycji pojazdu firmy.
    assert client.get(f"/api/companies/{company}/live", headers=as_user("jan")).status_code == 403
    assert (
        client.post(
            f"/api/vehicles/{truck}/position", json=position, headers=as_user("obcy")
        ).status_code
        == 404
    )

    with database.session() as db:
        stale = live.live_vehicles(
            db, company, live._now() + live.STALE_AFTER + timedelta(seconds=1)
        )
    assert (stale[0].state, stale[0].speed_kmh, stale[0].lat) == ("no_signal", None, 50.06)

    # Koniec nawigacji: pozycja zostaje jako ostatnia znana.
    end = position | {"driving": False}
    client.post(f"/api/vehicles/{truck}/position", json=end, headers=as_user("jan"))
    (ended,) = client.get(f"/api/companies/{company}/live", headers=as_user("owner")).json()
    assert (ended["state"], ended["destination"]) == ("stopped", None)


def test_private_vehicle_position_is_not_accepted(client):
    truck = client.post("/api/vehicles", json=TRUCK, headers=as_user("jan")).json()["id"]
    position = {"lat": 50.06, "lon": 19.94}

    assert (
        client.post(
            f"/api/vehicles/{truck}/position", json=position, headers=as_user("jan")
        ).status_code
        == 404
    )


def test_dispatcher_sends_route_with_own_start_to_driver(client):
    company = client.post("/api/companies", json=COMPANY, headers=as_user("owner")).json()["id"]
    join(client, company, "jan", "driver")
    join(client, company, "ewa", "dispatcher")
    truck = client.post(
        "/api/vehicles", json=TRUCK | {"company_id": company}, headers=as_user("owner")
    ).json()["id"]
    members = client.get(f"/api/companies/{company}", headers=as_user("ewa")).json()["members"]
    jan = next(m["id"] for m in members if m["display_name"].endswith("jan"))
    body = {
        "vehicle_id": truck,
        "driver_member_id": jan,
        # Pojazd stoi gdzie indziej – trasa zaczyna się w bazie załadunku.
        "origin": {"lat": 50.06, "lon": 19.94, "label": "Baza Kraków"},
        "via": [{"lat": 50.3, "lon": 19.0, "label": "Załadunek Katowice"}],
        "destination": {"lat": 45.76, "lon": 4.83, "label": "Lyon"},
        "note": "Rozładunek do 14:00",
        "distance_km": 1450.2,
    }

    assert (
        client.post(
            f"/api/companies/{company}/route-assignments", json=body, headers=as_user("jan")
        ).status_code
        == 403
    )
    sent = client.post(
        f"/api/companies/{company}/route-assignments", json=body, headers=as_user("ewa")
    )
    assert sent.status_code == 201
    assignment = sent.json()
    assert (assignment["origin"]["label"], assignment["via"][0]["label"]) == (
        "Baza Kraków",
        "Załadunek Katowice",
    )

    # Kierowca: wiadomość w skrzynce i trasa na liście do przejechania.
    messages = client.get("/api/me/messages", headers=as_user("jan")).json()["items"]
    (message,) = [m for m in messages if m["kind"] == "route_assigned"]
    assert message["data"]["assignment_id"] == assignment["id"]
    assert message["data"]["to"] == "Lyon"
    (mine,) = client.get("/api/me/route-assignments", headers=as_user("jan")).json()
    assert mine["note"] == "Rozładunek do 14:00"
    # Inny kierowca nie widzi cudzej trasy.
    join(client, company, "olek", "driver")
    assert (
        client.get(
            f"/api/route-assignments/{assignment['id']}", headers=as_user("olek")
        ).status_code
        == 404
    )

    accepted = client.post(
        f"/api/route-assignments/{assignment['id']}/state",
        json={"state": "accepted"},
        headers=as_user("jan"),
    )
    assert accepted.json()["state"] == "accepted"
    listed = client.get(
        f"/api/companies/{company}/route-assignments", headers=as_user("ewa")
    ).json()
    assert [(a["driver_name"].endswith("jan"), a["state"]) for a in listed] == [(True, "accepted")]
