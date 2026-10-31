import pytest
from fastapi.testclient import TestClient
from sqlalchemy.pool import StaticPool
from truckmaps_service.module import Base as ServiceBase
from truckmaps_service.module import ServiceModule

from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.config import Settings
from truckmaps.core.db import Base, Database
from truckmaps.sdk import Principal

TRUCK = {
    "name": "MAN TGX",
    "kind": "tractor",
    "height_m": 4.0,
    "width_m": 2.55,
    "length_m": 6.0,
    "gvw_t": 18,
    "axle_load_t": 11.5,
    "axle_count": 2,
}


class FakeVerifier:
    def verify(self, token: str) -> Principal:
        if not token.startswith("user-"):
            raise InvalidToken(token)
        subject = token.removeprefix("user-")
        return Principal(subject=subject, claims={"name": subject.title()})


def as_user(subject: str) -> dict:
    return {"Authorization": f"Bearer user-{subject}"}


@pytest.fixture
def client():
    database = Database(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(database.engine)
    ServiceBase.metadata.create_all(database.engine)
    app = create_app(
        Settings(dev_grant_all=True),
        modules=[ServiceModule()],
        token_verifier=FakeVerifier(),
        database=database,
    )
    with TestClient(app) as client:
        yield client


def join(client, company_id: str, subject: str, role: str) -> None:
    invite = client.post(
        f"/api/companies/{company_id}/invites", json={"role": role}, headers=as_user("olek")
    ).json()
    accepted = client.post(
        f"/api/invites/{invite['code']}/accept", json={}, headers=as_user(subject)
    )
    assert accepted.status_code == 200


@pytest.fixture
def fleet(client):
    company_id = client.post(
        "/api/companies", json={"name": "Trans-Miś"}, headers=as_user("olek")
    ).json()["id"]
    join(client, company_id, "marek", "mechanic")
    join(client, company_id, "jan", "driver")
    vehicle = client.post(
        "/api/vehicles", json=TRUCK | {"company_id": company_id}, headers=as_user("olek")
    ).json()
    return vehicle["id"]


def test_driver_reports_mechanic_repairs_with_protocol(client, fleet):
    report = client.post(
        "/api/m/service/orders",
        json={"vehicle_id": fleet, "description": "Wycieka olej", "urgency": "stopped"},
        headers=as_user("jan"),
    )
    assert report.status_code == 201
    order = report.json()
    assert (order["status"], order["reporter_name"], order["can_handle"]) == ("new", "Jan", False)
    vehicle = client.get(f"/api/vehicles/{fleet}", headers=as_user("olek")).json()
    assert vehicle["in_repair"] is True  # stoi – niedostępny od zgłoszenia

    url = f"/api/m/service/orders/{order['id']}"
    assert client.post(f"{url}/accept", headers=as_user("jan")).status_code == 403
    accepted = client.post(f"{url}/accept", headers=as_user("marek")).json()
    assert (accepted["status"], accepted["mechanic_name"]) == ("accepted", "Marek")
    assert client.post(f"{url}/accept", headers=as_user("marek")).status_code == 409
    assert client.post(f"{url}/start", headers=as_user("marek")).json()["status"] == "in_progress"

    protocol = {
        "work_done": "Wymiana uszczelki miski olejowej",
        "parts": [{"name": "Uszczelka", "quantity": 1, "price": 120}, {"name": "Olej 10W40"}],
        "labour_hours": 2.5,
        "odometer_km": 412000,
    }
    done = client.post(f"{url}/complete", json=protocol, headers=as_user("marek")).json()
    assert (done["status"], done["labour_hours"], len(done["parts"])) == ("done", 2.5, 2)
    assert done["completed_at"] is not None
    vehicle = client.get(f"/api/vehicles/{fleet}", headers=as_user("olek")).json()
    assert vehicle["in_repair"] is False

    history = client.get(
        "/api/m/service/orders", params={"vehicle_id": fleet}, headers=as_user("jan")
    ).json()
    assert [o["work_done"] for o in history] == ["Wymiana uszczelki miski olejowej"]
    assert client.get("/api/m/service/orders", headers=as_user("obcy")).json() == []


def test_reject_and_foreign_vehicle(client, fleet):
    order = client.post(
        "/api/m/service/orders",
        json={"vehicle_id": fleet, "description": "Stuk w zawieszeniu"},
        headers=as_user("jan"),
    ).json()
    vehicle = client.get(f"/api/vehicles/{fleet}", headers=as_user("olek")).json()
    assert vehicle["in_repair"] is False  # może jechać do naprawy

    rejected = client.post(
        f"/api/m/service/orders/{order['id']}/reject",
        json={"reason": "Zgłoszone wczoraj – zlecenie już jest"},
        headers=as_user("olek"),
    ).json()
    assert rejected["status"] == "rejected"
    open_orders = client.get(
        "/api/m/service/orders", params={"open_only": True}, headers=as_user("olek")
    ).json()
    assert open_orders == []

    foreign = client.post(
        "/api/m/service/orders",
        json={"vehicle_id": fleet, "description": "Cudzy pojazd"},
        headers=as_user("obcy"),
    )
    assert foreign.status_code == 404
    assert client.get(
        f"/api/m/service/orders/{order['id']}/x", headers=as_user("olek")
    ).status_code in (404, 405)
