import base64
from datetime import date, timedelta

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
    assert (vehicle["in_repair"], vehicle["repair_reported"]) == (True, False)  # stoi – w naprawie

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
    today = date.today()
    past = protocol | {"inspection_until": today.isoformat()}
    assert client.post(f"{url}/complete", json=past, headers=as_user("marek")).status_code == 422
    valid = (today + timedelta(days=365)).isoformat()
    protocol |= {"inspection_until": valid}
    done = client.post(f"{url}/complete", json=protocol, headers=as_user("marek")).json()
    assert (done["status"], done["labour_hours"], len(done["parts"])) == ("done", 2.5, 2)
    assert done["completed_at"] is not None
    assert done["inspection_until"] == valid
    vehicle = client.get(f"/api/vehicles/{fleet}", headers=as_user("olek")).json()
    assert (vehicle["in_repair"], vehicle["repair_reported"]) == (False, False)
    # Przegląd zrobiony w serwisie przesuwa terminy pojazdu.
    assert (vehicle["last_inspection"], vehicle["inspection_until"]) == (today.isoformat(), valid)

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
    assert (vehicle["in_repair"], vehicle["repair_reported"]) == (False, True)  # może jechać

    rejected = client.post(
        f"/api/m/service/orders/{order['id']}/reject",
        json={"reason": "Zgłoszone wczoraj – zlecenie już jest"},
        headers=as_user("olek"),
    ).json()
    assert rejected["status"] == "rejected"
    vehicle = client.get(f"/api/vehicles/{fleet}", headers=as_user("olek")).json()
    assert vehicle["repair_reported"] is False
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


JPEG = base64.b64encode(b"\xff\xd8\xff\xe0" + b"0" * 100).decode()


def messages(client, who):
    return client.get("/api/me/messages", headers=as_user(who)).json()["items"]


def test_photos_messages_protocol_and_costs(client, fleet):
    order = client.post(
        "/api/m/service/orders",
        json={"vehicle_id": fleet, "description": "Pęknięta szyba"},
        headers=as_user("jan"),
    ).json()
    url = f"/api/m/service/orders/{order['id']}"
    # O zgłoszeniu wie obsługa pojazdu (właściciel i mechanik), nie sam zgłaszający.
    assert [m["kind"] for m in messages(client, "marek")] == ["service.order_new"]
    assert messages(client, "olek")[0]["data"]["reporter_name"] == "Jan"
    assert messages(client, "jan") == []

    photo = client.post(f"{url}/photos", json={"image": JPEG}, headers=as_user("jan"))
    assert photo.status_code == 201
    shot = photo.json()["photos"][0]
    assert shot["stage"] == "report"
    got = client.get(f"/api/m/service/photos/{shot['id']}", headers=as_user("olek")).json()
    assert (got["content_type"], got["image"]) == ("image/jpeg", JPEG)
    assert (
        client.get(f"/api/m/service/photos/{shot['id']}", headers=as_user("obcy")).status_code
        == 404
    )
    bad = client.post(f"{url}/photos", json={"image": "bm90IGFuIGltYWdl"}, headers=as_user("jan"))
    assert bad.status_code == 422
    protocol_photo = {"image": JPEG, "stage": "protocol"}
    assert (
        client.post(f"{url}/photos", json=protocol_photo, headers=as_user("jan")).status_code == 403
    )

    assert client.get(f"{url}/protocol", headers=as_user("olek")).status_code == 409
    protocol = {
        "work_done": "Wymiana szyby",
        "parts": [
            {"name": "Szyba", "quantity": 1, "price": 1800},
            {"name": "Klej", "quantity": 2, "price": 50},
        ],
        "labour_hours": 3,
        "labour_rate": 150,
        "currency": "PLN",
    }
    client.post(f"{url}/complete", json=protocol, headers=as_user("marek"))
    done = messages(client, "jan")[0]
    assert (done["kind"], done["data"]["mechanic_name"]) == ("service.order_done", "Marek")

    page = client.get(f"{url}/protocol", headers=as_user("olek")).json()
    assert "Protokół naprawy" in page["html"] and "1900.00 PLN" in page["html"]
    assert "data:image/jpeg;base64," in page["html"]
    assert page["filename"].endswith("-MAN_TGX")
    assert "450.00 PLN" in page["html"] and "2350.00 PLN" in page["html"]  # robocizna i razem

    # Link do przeglądarki telefonu: bez logowania, tylko z kluczem, ważny kilka minut.
    link = client.post(f"{url}/protocol/link", headers=as_user("olek")).json()
    assert link["path"].startswith("/api/shared/")
    opened = client.get(link["path"])
    assert opened.status_code == 200 and "Protokół naprawy" in opened.text
    assert opened.headers["content-type"].startswith("text/html")
    assert client.get("/api/shared/zly-klucz").status_code == 404
    assert client.post(f"{url}/protocol/link", headers=as_user("obcy")).status_code in (403, 404)

    costs = client.get("/api/m/service/costs", headers=as_user("olek")).json()
    assert costs == [
        {
            "vehicle_id": fleet,
            "vehicle_name": "MAN TGX",
            "vehicle_plate": None,
            "currency": "PLN",
            "orders": 1,
            "parts_total": 1900.0,
            "labour_hours": 3.0,
            "labour_total": 450.0,
            "total": 2350.0,
        }
    ]
    one = client.get(
        "/api/m/service/costs", params={"vehicle_id": fleet}, headers=as_user("olek")
    ).json()
    assert [c["total"] for c in one] == [2350.0]
    other = client.get(
        "/api/m/service/costs", params={"vehicle_id": "inny"}, headers=as_user("olek")
    ).json()
    assert other == []
    assert client.get("/api/m/service/costs", headers=as_user("jan")).json() == []  # kierowca


def test_dashboard_shows_open_orders(client, fleet):
    company_id = client.get(f"/api/vehicles/{fleet}", headers=as_user("olek")).json()["company_id"]
    for urgency in ("stopped", "can_drive"):
        client.post(
            "/api/m/service/orders",
            json={"vehicle_id": fleet, "description": "Wycieka olej", "urgency": urgency},
            headers=as_user("jan"),
        )
    params = {"company_id": company_id}
    overview = client.get("/api/dashboard/overview", params=params, headers=as_user("olek")).json()
    open_orders = next(k for k in overview["kpis"] if k["key"] == "service.open")
    assert (open_orders["value"], open_orders["tone"]) == (2, "error")
    alerts = client.get("/api/dashboard/alerts", params=params, headers=as_user("olek")).json()
    orders = [a for a in alerts if a["kind"] == "service.order"]
    assert [a["severity"] for a in orders] == ["critical", "warning"]
    assert orders[0]["data"]["description"] == "Wycieka olej"
    assert orders[0]["vehicle_name"]
