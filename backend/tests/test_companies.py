from datetime import UTC, date, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import update

from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.companies import CompanyInvite
from truckmaps.core.config import Settings
from truckmaps.core.currency import store_rates
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


class StraightRouter:
    def locate(self, stops, vehicle):
        return [(p, 0.0) for p in stops]

    def route(self, stops, vehicle, exclude=None, alternates=0) -> Route:
        return Route(
            distance_km=310.0, duration_min=245.0, geometry=[(p.lon, p.lat) for p in stops]
        )


def as_user(subject: str) -> dict:
    return {"Authorization": f"Bearer user-{subject}"}


@pytest.fixture
def client(database):
    app = create_app(
        Settings(),
        modules=[],
        token_verifier=FakeVerifier(),
        database=database,
        router=StraightRouter(),
    )
    return TestClient(app)


def new_company(client, owner="olek", name="Trans-Miś") -> str:
    response = client.post(
        "/api/companies", json={"name": name, "display_name": "Olek"}, headers=as_user(owner)
    )
    assert response.status_code == 201
    return response.json()["id"]


def join(client, company_id, subject, role="driver", by="olek") -> dict:
    invite = client.post(
        f"/api/companies/{company_id}/invites", json={"role": role}, headers=as_user(by)
    )
    assert invite.status_code == 201, invite.json()
    response = client.post(
        f"/api/invites/{invite.json()['code']}/accept",
        json={"display_name": subject.title()},
        headers=as_user(subject),
    )
    assert response.status_code == 200, response.json()
    return response.json()


def test_creator_becomes_owner_and_others_see_nothing(client):
    company_id = new_company(client)

    (company,) = client.get("/api/companies", headers=as_user("olek")).json()
    assert (company["name"], company["role"]) == ("Trans-Miś", "owner")
    details = client.get(f"/api/companies/{company_id}", headers=as_user("olek")).json()
    assert [(m["display_name"], m["role"], m["is_me"]) for m in details["members"]] == [
        ("Olek", "owner", True)
    ]

    assert client.get("/api/companies", headers=as_user("obcy")).json() == []
    assert client.get(f"/api/companies/{company_id}", headers=as_user("obcy")).status_code == 404
    assert client.get("/api/companies").status_code == 401


def test_invite_code_joins_once_with_its_role(client):
    company_id = new_company(client)
    invite = client.post(
        f"/api/companies/{company_id}/invites",
        json={"role": "dispatcher", "note": "Ewa"},
        headers=as_user("olek"),
    ).json()
    assert len(invite["code"]) == 8

    # Kod można wpisać małymi literami i z myślnikiem.
    typed = invite["code"].lower()[:4] + "-" + invite["code"].lower()[4:]
    joined = client.post(f"/api/invites/{typed}/accept", json={}, headers=as_user("ewa"))
    assert joined.status_code == 200
    assert joined.json()["role"] == "dispatcher"

    again = client.post(f"/api/invites/{invite['code']}/accept", json={}, headers=as_user("jan"))
    assert again.status_code == 404
    assert client.get(f"/api/companies/{company_id}/invites", headers=as_user("olek")).json() == []


def test_expired_invite_is_rejected(client, database):
    company_id = new_company(client)
    code = client.post(
        f"/api/companies/{company_id}/invites", json={}, headers=as_user("olek")
    ).json()["code"]
    with database.session() as db:
        db.execute(
            update(CompanyInvite).values(expires_at=datetime.now(UTC) - timedelta(minutes=1))
        )
        db.commit()

    response = client.post(f"/api/invites/{code}/accept", json={}, headers=as_user("jan"))
    assert response.status_code == 404


def test_roles_limit_who_invites_and_manages(client):
    company_id = new_company(client)
    join(client, company_id, "ewa", role="dispatcher")
    join(client, company_id, "jan")
    url = f"/api/companies/{company_id}/invites"

    assert client.post(url, json={"role": "driver"}, headers=as_user("ewa")).status_code == 201
    assert client.post(url, json={"role": "owner"}, headers=as_user("ewa")).status_code == 403
    assert client.post(url, json={}, headers=as_user("jan")).status_code == 403

    members = client.get(f"/api/companies/{company_id}", headers=as_user("jan")).json()["members"]
    jan = next(m for m in members if m["display_name"] == "Jan")
    member_url = f"/api/companies/{company_id}/members/{jan['id']}"
    promote = {"role": "dispatcher"}
    assert client.put(member_url, json=promote, headers=as_user("ewa")).status_code == 403
    assert client.put(member_url, json=promote, headers=as_user("olek")).status_code == 200
    assert (
        client.put(
            f"/api/companies/{company_id}", json={"name": "Nowa"}, headers=as_user("ewa")
        ).status_code
        == 403
    )


def test_company_always_keeps_an_owner(client):
    company_id = new_company(client)
    join(client, company_id, "jan")
    olek = client.get(f"/api/companies/{company_id}", headers=as_user("olek")).json()["members"][0]
    olek_url = f"/api/companies/{company_id}/members/{olek['id']}"

    assert client.delete(olek_url, headers=as_user("olek")).status_code == 409
    demote = client.put(olek_url, json={"role": "driver"}, headers=as_user("olek"))
    assert demote.status_code == 409

    members = client.get(f"/api/companies/{company_id}", headers=as_user("jan")).json()["members"]
    jan = next(m for m in members if m["is_me"])
    jan_url = f"/api/companies/{company_id}/members/{jan['id']}"
    assert client.delete(olek_url, headers=as_user("jan")).status_code == 403
    assert client.delete(jan_url, headers=as_user("jan")).status_code == 204
    assert client.get("/api/companies", headers=as_user("jan")).json() == []


def test_company_vehicles_are_shared_but_edited_by_managers(client):
    company_id = new_company(client)
    join(client, company_id, "jan")
    fleet_truck = {**TRUCK, "name": "Firmowy", "company_id": company_id}

    assert client.post("/api/vehicles", json=fleet_truck, headers=as_user("jan")).status_code == 403
    created = client.post("/api/vehicles", json=fleet_truck, headers=as_user("olek"))
    assert created.status_code == 201
    vehicle_id = created.json()["id"]
    client.post("/api/vehicles", json={**TRUCK, "name": "Prywatny Olka"}, headers=as_user("olek"))

    jan_sees = client.get("/api/vehicles", headers=as_user("jan")).json()
    assert [(v["name"], v["can_edit"]) for v in jan_sees] == [("Firmowy", False)]
    assert client.get("/api/vehicles", headers=as_user("obcy")).json() == []

    url = f"/api/vehicles/{vehicle_id}"
    assert client.put(url, json=fleet_truck, headers=as_user("jan")).status_code == 403
    assert client.delete(url, headers=as_user("jan")).status_code == 403
    assert client.get(url, headers=as_user("obcy")).status_code == 404

    # Kierowca firmy wyznacza trasę jej pojazdem.
    route = client.post(
        "/api/routes",
        json={"vehicle_id": vehicle_id, "origin": POZNAN, "destination": WARSAW},
        headers=as_user("jan"),
    )
    assert route.status_code == 200


def test_vehicle_cannot_be_put_into_foreign_company(client):
    company_id = new_company(client)
    truck = {**TRUCK, "company_id": company_id}

    assert client.post("/api/vehicles", json=truck, headers=as_user("obcy")).status_code == 404


def test_deleting_company_returns_vehicles_to_their_creator(client):
    company_id = new_company(client)
    join(client, company_id, "jan")
    fleet_truck = {**TRUCK, "name": "Firmowy", "company_id": company_id}
    client.post("/api/vehicles", json=fleet_truck, headers=as_user("olek"))

    assert client.delete(f"/api/companies/{company_id}", headers=as_user("jan")).status_code == 403
    assert client.delete(f"/api/companies/{company_id}", headers=as_user("olek")).status_code == 204

    (vehicle,) = client.get("/api/vehicles", headers=as_user("olek")).json()
    assert (vehicle["name"], vehicle["company_id"], vehicle["can_edit"]) == ("Firmowy", None, True)
    assert client.get("/api/vehicles", headers=as_user("jan")).json() == []


def route_cost(client, vehicle_id, who="olek"):
    response = client.post(
        "/api/routes",
        json={"vehicle_id": vehicle_id, "origin": POZNAN, "destination": WARSAW},
        headers=as_user(who),
    )
    assert response.status_code == 200
    return response.json()["cost"]


def test_route_cost_uses_vehicle_rates_then_company_rates(client):
    company_id = new_company(client)
    join(client, company_id, "jan")
    vehicle = client.post(
        "/api/vehicles", json={**TRUCK, "company_id": company_id}, headers=as_user("olek")
    ).json()

    # Bez stawek nie zgadujemy kosztu.
    assert route_cost(client, vehicle["id"]) is None

    rates = {"name": "Trans-Miś", "cost_per_km": 1.0, "cost_per_hour": 30}
    client.put(f"/api/companies/{company_id}", json=rates, headers=as_user("olek"))
    cost = route_cost(client, vehicle["id"], who="jan")
    # 310 km × 1,0 € + 245 min = 4,083 h × 30 €
    assert (cost["amount"], cost["currency"], cost["source"]) == (432.5, "EUR", "company")
    assert (cost["provider"], cost["estimated"], cost["exchange_day"]) == ("core", True, None)

    own_km_rate = {**TRUCK, "company_id": company_id, "cost_per_km": 1.2}
    client.put(f"/api/vehicles/{vehicle['id']}", json=own_km_rate, headers=as_user("olek"))
    cost = route_cost(client, vehicle["id"])
    assert (cost["amount"], cost["per_km"], cost["source"]) == (494.5, 1.2, "mixed")


def test_private_vehicle_rates_and_validation(client):
    private = {**TRUCK, "cost_per_km": 0.9}
    vehicle = client.post("/api/vehicles", json=private, headers=as_user("ola")).json()

    cost = route_cost(client, vehicle["id"], who="ola")
    assert (cost["amount"], cost["per_hour"], cost["source"]) == (279.0, 0.0, "vehicle")

    negative = {**TRUCK, "cost_per_km": -1}
    assert client.post("/api/vehicles", json=negative, headers=as_user("ola")).status_code == 422
    unknown = {**TRUCK, "cost_per_km": 1, "cost_currency": "XYZ"}
    assert client.post("/api/vehicles", json=unknown, headers=as_user("ola")).status_code == 422


def add_rates(database, day="2026-10-28", **per_eur):
    with database.session() as db:
        store_rates(db, date.fromisoformat(day), per_eur)


def test_route_cost_in_chosen_currency_with_ecb_rate(client, database):
    company_id = new_company(client)
    vehicle = client.post(
        "/api/vehicles",
        json={**TRUCK, "company_id": company_id, "cost_per_km": 4.0, "cost_currency": "PLN"},
        headers=as_user("olek"),
    ).json()
    hourly = {"name": "Trans-Miś", "cost_per_hour": 30, "cost_currency": "EUR"}
    client.put(f"/api/companies/{company_id}", json=hourly, headers=as_user("olek"))

    # Stawki w PLN i EUR, a kursu jeszcze nie ma – kosztu nie zgadujemy.
    assert route_cost(client, vehicle["id"]) is None

    add_rates(database, PLN=4.0, CZK=25.0)
    # Bez wyboru użytkownika: waluta firmy (EUR). 310 km × 4 zł = 310 € + 4,083 h × 30 €.
    cost = route_cost(client, vehicle["id"])
    assert (cost["amount"], cost["currency"], cost["per_km"]) == (432.5, "EUR", 1.0)
    assert (cost["rates_currencies"], cost["exchange_day"]) == (["EUR", "PLN"], "2026-10-28")

    settings = client.put("/api/me/settings", json={"currency": "czk"}, headers=as_user("olek"))
    assert settings.json()["currency"] == "CZK"
    cost = route_cost(client, vehicle["id"])
    assert (cost["amount"], cost["currency"]) == (10812.5, "CZK")
    assert client.get("/api/me/settings", headers=as_user("olek")).json()["currency"] == "CZK"

    currencies = client.get("/api/currencies", headers=as_user("olek")).json()
    assert currencies["rates_day"] == "2026-10-28"
    assert currencies["per_eur"] == {"PLN": 4.0, "CZK": 25.0}
    assert currencies["currencies"][0] == {"code": "PLN", "name": "złoty polski"}


def test_cost_stays_in_rates_currency_without_exchange_rate(client):
    private = {**TRUCK, "cost_per_km": 4.0, "cost_currency": "PLN"}
    vehicle = client.post("/api/vehicles", json=private, headers=as_user("ola")).json()
    client.put("/api/me/settings", json={"currency": "EUR"}, headers=as_user("ola"))

    cost = route_cost(client, vehicle["id"], who="ola")
    assert (cost["amount"], cost["currency"], cost["exchange_day"]) == (1240.0, "PLN", None)


def test_company_bases_are_shared_with_members_and_managed_by_dispatchers(client):
    company_id = new_company(client)
    join(client, company_id, "jan")
    join(client, company_id, "ewa", role="dispatcher")
    url = f"/api/companies/{company_id}/bases"
    base = {"name": "Baza Tarnów", "label": "Chemiczna 5, Tarnów", "lat": 50.0286, "lon": 20.9135}

    assert client.post(url, json=base, headers=as_user("jan")).status_code == 403
    created = client.post(url, json=base, headers=as_user("ewa"))
    assert created.status_code == 201
    base_id = created.json()["id"]

    (seen,) = client.get("/api/bases", headers=as_user("jan")).json()
    assert (seen["name"], seen["company_name"], seen["lat"]) == (
        "Baza Tarnów",
        "Trans-Miś",
        50.0286,
    )
    assert client.get("/api/bases", headers=as_user("obcy")).json() == []

    renamed = client.put(
        f"{url}/{base_id}", json={**base, "name": "Baza główna"}, headers=as_user("olek")
    )
    assert renamed.json()["name"] == "Baza główna"
    assert client.delete(f"{url}/{base_id}", headers=as_user("jan")).status_code == 403
    assert client.delete(f"{url}/{base_id}", headers=as_user("olek")).status_code == 204
    assert client.get("/api/bases", headers=as_user("olek")).json() == []


def test_deleting_company_removes_its_bases(client):
    company_id = new_company(client)
    base = {"name": "Baza", "lat": 50.0, "lon": 20.0}
    client.post(f"/api/companies/{company_id}/bases", json=base, headers=as_user("olek"))

    client.delete(f"/api/companies/{company_id}", headers=as_user("olek"))

    assert client.get("/api/bases", headers=as_user("olek")).json() == []


def test_account_settings_name_language_and_first_login(client):
    me = client.get("/api/me/settings", headers=as_user("jan")).json()
    assert me == {
        "currency": None,
        "display_name": "Użytkownik jan",
        "language": None,
        "onboarded": False,
    }

    # Sam, bez firmy: tylko znacznik; reszta ustawień zostaje, jak była.
    client.put("/api/me/settings", json={"currency": "PLN"}, headers=as_user("jan"))
    me = client.put("/api/me/settings", json={"onboarded": True}, headers=as_user("jan")).json()
    assert (me["currency"], me["onboarded"]) == ("PLN", True)

    bad = client.put("/api/me/settings", json={"language": "xx"}, headers=as_user("jan"))
    assert bad.status_code == 422
    me = client.put(
        "/api/me/settings",
        json={"language": "EN", "display_name": " Jan K. "},
        headers=as_user("jan"),
    ).json()
    assert (me["language"], me["display_name"], me["currency"]) == ("en", "Jan K.", "PLN")

    # Dołączenie kodem kończy pierwsze logowanie; nowe imię widać w firmie.
    company_id = new_company(client)
    join(client, company_id, "ewa")
    assert client.get("/api/me/settings", headers=as_user("ewa")).json()["onboarded"] is True
    assert client.get("/api/me/settings", headers=as_user("olek")).json()["onboarded"] is True
    client.put("/api/me/settings", json={"display_name": "Ewa Nowak"}, headers=as_user("ewa"))
    members = client.get(f"/api/companies/{company_id}", headers=as_user("olek")).json()["members"]
    assert [m["display_name"] for m in members] == ["Olek", "Ewa Nowak"]


def test_company_kind_limits_fleet_and_roles(client):
    def create(kind):
        body = {"name": f"Firma {kind}", "kind": kind}
        response = client.post("/api/companies", json=body, headers=as_user("olek"))
        assert response.status_code == 201
        assert response.json()["kind"] == kind
        return response.json()["id"]

    forwarder, passenger, carrier = create("forwarder"), create("passenger"), create("carrier")
    bus = TRUCK | {"kind": "bus", "seats": 49}

    def add(company_id, body):
        return client.post(
            "/api/vehicles", json=body | {"company_id": company_id}, headers=as_user("olek")
        )

    # Spedycja: bez floty i bez kierowców.
    no_fleet = add(forwarder, TRUCK)
    assert no_fleet.status_code == 422
    assert no_fleet.json()["detail"].startswith("Spedycja nie ma własnej floty")
    invite = client.post(
        f"/api/companies/{forwarder}/invites", json={"role": "driver"}, headers=as_user("olek")
    )
    assert invite.status_code == 422
    join(client, forwarder, "ewa", role="dispatcher")

    # Transport osób – autobusy i przyczepy; przewoźnik towarów – bez autobusów.
    assert add(passenger, bus).status_code == 201
    assert add(passenger, TRUCK | {"kind": "tractor"}).status_code == 422
    assert add(carrier, TRUCK | {"kind": "tractor"}).status_code == 201
    assert add(carrier, bus).status_code == 422

    # Zmiana na spedycję – tylko bez floty i kierowców.
    change = {"name": "Firma carrier", "kind": "forwarder"}
    blocked = client.put(f"/api/companies/{carrier}", json=change, headers=as_user("olek"))
    assert blocked.status_code == 409
    to_passenger = client.put(
        f"/api/companies/{forwarder}",
        json={"name": "Firma forwarder", "kind": "passenger"},
        headers=as_user("olek"),
    )
    assert to_passenger.json()["kind"] == "passenger"
