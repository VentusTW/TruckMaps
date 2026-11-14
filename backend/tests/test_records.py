import base64
from datetime import date, timedelta

import pytest
from fastapi.testclient import TestClient

from truckmaps.core import records
from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.config import Settings
from truckmaps.sdk import Principal


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


@pytest.fixture
def company(client) -> str:
    return client.post("/api/companies", json={"name": "Trans"}, headers=as_user("owner")).json()[
        "id"
    ]


def join(client, company: str, who: str, role: str) -> None:
    code = client.post(
        f"/api/companies/{company}/invites", json={"role": role}, headers=as_user("owner")
    ).json()["code"]
    client.post(f"/api/invites/{code}/accept", json={}, headers=as_user(who))


def test_records_scoped_to_company_and_writers(client, company):
    join(client, company, "jan", "driver")
    base = f"/api/companies/{company}/records"
    leave = {
        "entity_type": "driver",
        "entity_id": "d1",
        "kind": "leave",
        "data": {"from": "2026-12-01"},
    }

    assert client.post(base, json=leave, headers=as_user("jan")).status_code == 403
    created = client.post(base, json=leave, headers=as_user("owner")).json()
    assert (
        client.get(base, params={"kind": "leave"}, headers=as_user("jan")).json()[0]["id"]
        == created["id"]
    )
    assert client.get(base, headers=as_user("obcy")).status_code == 404

    updated = client.put(
        f"{base}/{created['id']}", json={"data": {"from": "2026-12-02"}}, headers=as_user("owner")
    )
    assert updated.json()["data"] == {"from": "2026-12-02"}
    assert client.delete(f"{base}/{created['id']}", headers=as_user("owner")).status_code == 204
    assert client.get(base, headers=as_user("owner")).json() == []


def test_files_and_settings(client, company):
    files = f"/api/companies/{company}/files"
    body = {
        "entity_type": "vehicle",
        "entity_id": "v1",
        "kind": "photo",
        "name": "zdjecie.png",
        "content_type": "image/png",
        "data": base64.b64encode(b"PNG-dane").decode(),
    }
    added = client.post(files, json=body, headers=as_user("owner")).json()
    listed = client.get(
        files, params={"entity_type": "vehicle", "entity_id": "v1"}, headers=as_user("owner")
    )
    assert [f["name"] for f in listed.json()] == ["zdjecie.png"]
    assert client.get(f"{files}/{added['id']}", headers=as_user("owner")).content == b"PNG-dane"
    big = body | {"data": base64.b64encode(b"x" * (records.MAX_FILE_BYTES + 1)).decode()}
    assert client.post(files, json=big, headers=as_user("owner")).status_code == 413

    settings = f"/api/companies/{company}/settings"
    assert client.put(f"{settings}/bays", json=6, headers=as_user("owner")).json() == {"bays": 6}
    assert client.get(settings, headers=as_user("owner")).json() == {"bays": 6}


def test_scheduled_report_goes_to_office_once_per_period(client, company, database):
    join(client, company, "ewa", "dispatcher")
    join(client, company, "jan", "driver")
    client.put(
        f"/api/companies/{company}/settings/report_schedule",
        json="weekly",
        headers=as_user("owner"),
    )
    today = date.today()

    with database.session() as db:
        assert records.send_scheduled_reports(db, today) == 2  # właściciel i dyspozytor
        assert records.send_scheduled_reports(db, today + timedelta(days=3)) == 0
        assert records.send_scheduled_reports(db, today + timedelta(days=7)) == 2

    kinds = [
        m["kind"] for m in client.get("/api/me/messages", headers=as_user("ewa")).json()["items"]
    ]
    assert kinds.count("report_scheduled") == 2
    assert client.get("/api/me/messages", headers=as_user("jan")).json()["items"] == []


def test_fuel_prices_latest_bulletin(client, database):
    from datetime import date as day

    from truckmaps.core.fuel_prices import FuelPrice

    with database.session() as db:
        db.add_all([
            FuelPrice(day=day(2026, 11, 2), country="PL", diesel_eur=1.40),
            FuelPrice(day=day(2026, 11, 9), country="PL", diesel_eur=1.42),
            FuelPrice(day=day(2026, 11, 9), country="DE", diesel_eur=1.65),
        ])  # fmt: skip
        db.commit()

    prices = client.get("/api/fuel-prices", headers=as_user("owner")).json()
    assert prices == {"day": "2026-11-09", "diesel_eur": {"PL": 1.42, "DE": 1.65}}
