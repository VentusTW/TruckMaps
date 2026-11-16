import pytest
from fastapi.testclient import TestClient

from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.config import Settings
from truckmaps.sdk import Principal

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
    app = create_app(
        Settings(dev_grant_all=True), modules=[], token_verifier=FakeVerifier(), database=database
    )
    return TestClient(app)


def join(client, company: str, who: str, role: str) -> None:
    code = client.post(
        f"/api/companies/{company}/invites", json={"role": role}, headers=as_user("owner")
    ).json()["code"]
    client.post(f"/api/invites/{code}/accept", json={}, headers=as_user(who))


@pytest.fixture
def setup(client):
    company = client.post("/api/companies", json={"name": "Trans"}, headers=as_user("owner"))
    company = company.json()["id"]
    join(client, company, "jan", "driver")
    truck = client.post(
        "/api/vehicles", json=TRUCK | {"company_id": company}, headers=as_user("owner")
    ).json()["id"]
    members = client.get(f"/api/companies/{company}", headers=as_user("owner")).json()["members"]
    jan = next(m["id"] for m in members if m["role"] == "driver")

    def send(distance_km: float | None, to: str = "Lyon") -> str:
        body = {
            "vehicle_id": truck,
            "driver_member_id": jan,
            "origin": {"lat": 50.06, "lon": 19.94, "label": "Kraków"},
            "destination": {"lat": 45.76, "lon": 4.83, "label": to},
            "distance_km": distance_km,
        }
        return client.post(
            f"/api/companies/{company}/route-assignments", json=body, headers=as_user("owner")
        ).json()["id"]

    return company, truck, send


def test_revenue_entered_per_order_and_summarized(client, setup):
    company, truck, send = setup
    lyon, berlin, local = send(1450.0), send(600.0, "Berlin"), send(None, "Wieliczka")
    base = f"/api/companies/{company}/route-assignments"

    # Kierowca nie wpisuje przychodów ani ich nie widzi.
    assert (
        client.put(f"{base}/{lyon}/revenue", json={"amount": 9000}, headers=as_user("jan"))
    ).status_code == 403
    assert (
        client.get(f"/api/companies/{company}/revenue/summary", headers=as_user("jan"))
    ).status_code == 403

    saved = client.put(
        f"{base}/{lyon}/revenue", json={"amount": 9000, "currency": "pln"}, headers=as_user("owner")
    ).json()
    assert (saved["amount"], saved["currency"], saved["plate"]) == (9000, "PLN", "KR 1234A")
    # Stawka za km: kwota = stawka × długość trasy.
    by_rate = client.put(
        f"{base}/{berlin}/revenue", json={"rate_per_km": 5.5}, headers=as_user("owner")
    ).json()
    assert (by_rate["amount"], by_rate["rate_per_km"]) == (3300, 5.5)
    # Bez długości trasy stawka za km nie wystarcza.
    assert (
        client.put(f"{base}/{local}/revenue", json={"rate_per_km": 5}, headers=as_user("owner"))
    ).status_code == 422
    assert (
        client.put(f"{base}/{local}/revenue", json={}, headers=as_user("owner"))
    ).status_code == 422
    client.put(f"{base}/{local}/revenue", json={"amount": 700}, headers=as_user("owner"))
    # Zmiana nadpisuje wpis zamiast dodawać drugi.
    client.put(f"{base}/{lyon}/revenue", json={"amount": 9500}, headers=as_user("owner"))

    summary = client.get(
        f"/api/companies/{company}/revenue/summary?months=3", headers=as_user("owner")
    ).json()
    assert (summary["count"], summary["orders_total"]) == (3, 3)
    assert summary["total"] == 13500
    assert summary["amount"] == {"PLN": 13500}
    assert summary["km"] == 2050
    # Na km tylko zlecenia ze znaną długością trasy.
    assert summary["per_km"] == round(12800 / 2050, 2)
    (vehicle,) = summary["vehicles"]
    assert (vehicle["vehicle_id"], vehicle["count"], vehicle["total"]) == (truck, 3, 13500)
    assert sum(m["total"] for m in summary["months"]) == 13500
    assert {o["label"] for o in summary["orders"]} == {
        "Kraków → Lyon",
        "Kraków → Berlin",
        "Kraków → Wieliczka",
    }

    assert (client.delete(f"{base}/{local}/revenue", headers=as_user("owner"))).status_code == 204
    summary = client.get(
        f"/api/companies/{company}/revenue/summary", headers=as_user("owner")
    ).json()
    assert (summary["count"], summary["total"]) == (2, 12800)
    assert next(o for o in summary["orders"] if o["assignment_id"] == local)["amount"] is None


def test_foreign_currency_without_rate_is_kept_apart(client, setup):
    company, _, send = setup
    order = send(1000.0)
    client.put(
        f"/api/companies/{company}/route-assignments/{order}/revenue",
        json={"amount": 2000, "currency": "EUR"},
        headers=as_user("owner"),
    )
    summary = client.get(
        f"/api/companies/{company}/revenue/summary", headers=as_user("owner")
    ).json()
    assert summary["amount"] == {"EUR": 2000}
    assert (summary["total"], summary["unconverted"], summary["per_km"]) == (0, ["EUR"], None)


def test_other_company_order_not_found(client, setup):
    company, _, send = setup
    order = send(100.0)
    other = client.post("/api/companies", json={"name": "Inna"}, headers=as_user("ola")).json()
    assert (
        client.put(
            f"/api/companies/{other['id']}/route-assignments/{order}/revenue",
            json={"amount": 1},
            headers=as_user("ola"),
        )
    ).status_code == 404
    assert (
        client.put(
            f"/api/companies/{company}/route-assignments/{order}/revenue",
            json={"amount": 1},
            headers=as_user("ola"),
        )
    ).status_code == 404
