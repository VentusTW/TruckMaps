from datetime import date, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.pool import StaticPool
from truckmaps_drivers import rules
from truckmaps_drivers.module import Base as DriversBase
from truckmaps_drivers.module import DriversModule

from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.config import Settings
from truckmaps.core.db import Base, Database
from truckmaps.core.routing import Route
from truckmaps.sdk import DrivingInfo, Principal

TRACTOR = {
    "name": "MAN TGX",
    "kind": "tractor",
    "height_m": 4.0,
    "width_m": 2.55,
    "length_m": 6.0,
    "gvw_t": 18,
    "axle_load_t": 11.5,
    "axle_count": 2,
}
SEMITRAILER = TRACTOR | {"name": "Krone", "kind": "semitrailer", "length_m": 13.6, "gvw_t": 24}


class FakeVerifier:
    def verify(self, token: str) -> Principal:
        if not token.startswith("user-"):
            raise InvalidToken(token)
        subject = token.removeprefix("user-")
        return Principal(subject=subject, claims={"name": subject.title()})


class FakeRouter:
    def locate(self, stops, vehicle):
        return [(p, 0.0) for p in stops]

    def route(self, stops, vehicle, exclude=None, alternates=0) -> Route:
        return Route(
            distance_km=310.4,
            duration_min=245.0,
            geometry=[(p.lon, p.lat) for p in stops],
            edges=None,
        )


def as_user(subject: str) -> dict:
    return {"Authorization": f"Bearer user-{subject}"}


@pytest.fixture
def module():
    return DriversModule()


@pytest.fixture
def database():
    database = Database(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(database.engine)
    DriversBase.metadata.create_all(database.engine)
    return database


@pytest.fixture
def client(database, module):
    app = create_app(
        Settings(dev_grant_all=True),
        modules=[module],
        token_verifier=FakeVerifier(),
        database=database,
        router=FakeRouter(),
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
def company(client):
    company_id = client.post(
        "/api/companies", json={"name": "Trans-Miś"}, headers=as_user("olek")
    ).json()["id"]
    join(client, company_id, "jan", "driver")
    join(client, company_id, "marek", "mechanic")
    tractor = client.post(
        "/api/vehicles", json=TRACTOR | {"company_id": company_id}, headers=as_user("olek")
    ).json()
    trailer = client.post(
        "/api/vehicles", json=SEMITRAILER | {"company_id": company_id}, headers=as_user("olek")
    ).json()
    return {"id": company_id, "tractor": tractor["id"], "trailer": trailer["id"]}


def member_id(client, company_id: str, subject: str) -> str:
    candidates = client.get(
        "/api/m/drivers/candidates", params={"company_id": company_id}, headers=as_user("olek")
    ).json()
    return next(c["member_id"] for c in candidates if c["name"] == subject.title())


def test_register_crud_permissions_and_history(client, company):
    today = date.today()
    body = {
        "company_id": company["id"],
        "name": "Jan Kowalski",
        "phone": "+48 600 100 200",
        "hired_on": "2024-03-01",
        "member_id": member_id(client, company["id"], "jan"),
        "license_categories": ["b", "C", "c+e"],
        "medical_until": (today + timedelta(days=10)).isoformat(),
    }
    assert (
        client.post("/api/m/drivers/drivers", json=body, headers=as_user("jan")).status_code == 403
    )
    assert (
        client.post("/api/m/drivers/drivers", json=body, headers=as_user("obcy")).status_code == 404
    )
    created = client.post("/api/m/drivers/drivers", json=body, headers=as_user("olek"))
    assert created.status_code == 201
    driver = created.json()
    assert driver["license_categories"] == ["B", "C", "CE"]
    assert (driver["has_account"], driver["member_name"], driver["can_edit"]) == (True, "Jan", True)
    assert [(d["field"], d["state"]) for d in driver["dues"]] == [("medical_until", "soon")]
    again = client.post("/api/m/drivers/drivers", json=body, headers=as_user("olek"))
    assert again.status_code == 409  # konto ma już kartę

    bad = body | {"license_categories": ["X"]}
    assert (
        client.post("/api/m/drivers/drivers", json=bad, headers=as_user("olek")).status_code == 422
    )

    # Kierowca widzi tylko swoją kartę i jej nie zmienia; mechanik nie widzi kartoteki.
    assert [
        d["id"] for d in client.get("/api/m/drivers/drivers", headers=as_user("jan")).json()
    ] == [driver["id"]]
    assert client.get("/api/m/drivers/drivers", headers=as_user("marek")).json() == []
    url = f"/api/m/drivers/drivers/{driver['id']}"
    mine = client.get(url, headers=as_user("jan")).json()
    assert mine["can_edit"] is False
    update = body | {"phone": "+48 600 999 999"}
    assert client.put(url, json=update, headers=as_user("jan")).status_code == 403
    changed = client.put(url, json=update, headers=as_user("olek")).json()
    assert changed["phone"] == "+48 600 999 999"

    # Pobranie z karty – może zrobić sam kierowca; następne za 28 dni.
    card = client.post(f"{url}/card-download", headers=as_user("jan")).json()
    assert card["card_download_until"] == (today + timedelta(days=28)).isoformat()

    history = client.get(f"{url}/history", headers=as_user("olek")).json()
    assert [h["action"] for h in history] == ["card_download", "updated", "created"]
    assert history[1]["changes"]["phone"] == ["+48 600 100 200", "+48 600 999 999"]
    assert history[1]["by_name"] == "Olek"

    # Wpis bez konta.
    other = client.post(
        "/api/m/drivers/drivers",
        json={"company_id": company["id"], "name": "Piotr Nowak"},
        headers=as_user("olek"),
    ).json()
    assert other["has_account"] is False
    names = [
        d["name"] for d in client.get("/api/m/drivers/drivers", headers=as_user("olek")).json()
    ]
    assert names == ["Jan Kowalski", "Piotr Nowak"]

    assert client.delete(url, headers=as_user("jan")).status_code == 403
    assert client.delete(url, headers=as_user("olek")).status_code == 204
    assert client.get(url, headers=as_user("olek")).status_code == 404


def test_assignment_with_warnings_and_history(client, company):
    jan = client.post(
        "/api/m/drivers/drivers",
        json={
            "company_id": company["id"],
            "name": "Jan Kowalski",
            "member_id": member_id(client, company["id"], "jan"),
            "license_categories": ["C"],
        },
        headers=as_user("olek"),
    ).json()
    url = f"/api/m/drivers/drivers/{jan['id']}"
    tractor, trailer = company["tractor"], company["trailer"]
    # Zestaw z naczepą wymaga C+E.
    client.put(
        f"/api/vehicles/{tractor}/trailer", json={"trailer_id": trailer}, headers=as_user("olek")
    )
    check = client.get(f"{url}/check", params={"vehicle_id": tractor}, headers=as_user("olek"))
    assert check.json()["required_category"] == "CE"
    assert "CE" in check.json()["warnings"][0]
    assert (
        client.get(
            f"{url}/check", params={"vehicle_id": trailer}, headers=as_user("olek")
        ).status_code
        == 422
    )

    assigned = client.post(f"{url}/assign", json={"vehicle_id": tractor}, headers=as_user("olek"))
    assert assigned.status_code == 200
    assert len(assigned.json()["warnings"]) == 1  # ostrzeżenie nie blokuje
    assert [v["name"] for v in assigned.json()["driver"]["vehicles"]] == ["MAN TGX"]
    vehicle = client.get(f"/api/vehicles/{tractor}", headers=as_user("olek")).json()
    assert vehicle["assigned_driver_name"] == "Jan"  # przydział rdzenia

    # Trasa: uwaga o kierowcy w odpowiedzi.
    route = client.post(
        "/api/routes",
        json={
            "vehicle_id": tractor,
            "origin": {"lat": 52.23, "lon": 21.01},
            "destination": {"lat": 50.06, "lon": 19.94},
        },
        headers=as_user("jan"),
    )
    assert route.status_code == 200, route.text
    assert route.json()["driver_warnings"][0].startswith("Jan Kowalski: ")

    # Piotr bez konta przejmuje pojazd – przydział Jana się kończy (także w rdzeniu).
    piotr = client.post(
        "/api/m/drivers/drivers",
        json={"company_id": company["id"], "name": "Piotr Nowak", "license_categories": ["CE"]},
        headers=as_user("olek"),
    ).json()
    purl = f"/api/m/drivers/drivers/{piotr['id']}"
    taken = client.post(f"{purl}/assign", json={"vehicle_id": tractor}, headers=as_user("olek"))
    assert taken.json()["warnings"] == []
    assert client.get(url, headers=as_user("olek")).json()["vehicles"] == []
    vehicle = client.get(f"/api/vehicles/{tractor}", headers=as_user("olek")).json()
    assert vehicle["assigned_driver_name"] == "Piotr Nowak"  # kierowca z kartoteki, bez konta

    # Przydział zmieniony w „Pojazdach” – historia modułu nadąża.
    members = client.get(f"/api/companies/{company['id']}", headers=as_user("olek")).json()
    jan_member = next(m["id"] for m in members["members"] if m["display_name"] == "Jan")
    client.put(
        f"/api/vehicles/{tractor}/driver", json={"member_id": jan_member}, headers=as_user("olek")
    )
    assert [v["name"] for v in client.get(url, headers=as_user("olek")).json()["vehicles"]] == [
        "MAN TGX"
    ]
    assert client.get(purl, headers=as_user("olek")).json()["vehicles"] == []
    history = client.get(f"{url}/assignments", headers=as_user("olek")).json()
    assert [h["ended_at"] is None for h in history] == [True, False]

    released = client.post(f"{url}/release", json={"vehicle_id": tractor}, headers=as_user("olek"))
    assert released.json()["vehicles"] == []
    vehicle = client.get(f"/api/vehicles/{tractor}", headers=as_user("olek")).json()
    assert vehicle["assigned_driver_name"] is None


def test_stats_from_trips(client, company):
    jan = client.post(
        "/api/m/drivers/drivers",
        json={
            "company_id": company["id"],
            "name": "Jan Kowalski",
            "member_id": member_id(client, company["id"], "jan"),
        },
        headers=as_user("olek"),
    ).json()
    start = date.today().isoformat()
    for km, loaded in [(300.0, True), (120.0, False)]:
        trip = {
            "started_at": f"{start}T06:00:00Z",
            "ended_at": f"{start}T10:00:00Z",
            "distance_km": km,
            "loaded": loaded,
            "idle_min": 30,
        }
        saved = client.post(
            f"/api/vehicles/{company['tractor']}/trips", json=trip, headers=as_user("jan")
        )
        assert saved.status_code == 201
    stats = client.get(f"/api/m/drivers/drivers/{jan['id']}/stats", headers=as_user("olek")).json()
    assert (stats["trips"], stats["distance_km"], stats["hours"]) == (2, 420.0, 8.0)
    assert (stats["empty_km"], stats["idle_hours"], stats["vehicles"]) == (120.0, 1.0, 1)
    assert stats["months"][0]["trips"] == 2
    assert stats["by_vehicle"][0]["name"] == "MAN TGX"

    # Bez konta: przejazdy pojazdu w czasie przydziału.
    piotr = client.post(
        "/api/m/drivers/drivers",
        json={"company_id": company["id"], "name": "Piotr Nowak"},
        headers=as_user("olek"),
    ).json()
    empty = client.get(f"/api/m/drivers/drivers/{piotr['id']}/stats", headers=as_user("olek"))
    assert empty.json()["trips"] == 0


def test_reminders_once_before_and_after(client, company, module, database):
    today = date.today()
    client.post(
        "/api/m/drivers/drivers",
        json={
            "company_id": company["id"],
            "name": "Jan Kowalski",
            "member_id": member_id(client, company["id"], "jan"),
            "code95_until": (today + timedelta(days=20)).isoformat(),
            "license_until": (today + timedelta(days=400)).isoformat(),
        },
        headers=as_user("olek"),
    )
    with database.session() as db:
        assert module.send_reminders(db) == 2  # właściciel i sam kierowca
        db.commit()
        assert module.send_reminders(db) == 0  # raz na termin
    messages = client.get("/api/me/messages", headers=as_user("jan")).json()["items"]
    due = [m for m in messages if m["kind"] == "drivers.due"]
    assert due[0]["data"]["field"] == "code95_until"
    assert due[0]["data"]["overdue"] is False
    assert client.get("/api/me/messages", headers=as_user("marek")).json()["items"] == []


def info(kind: str, gvw: float, **extra) -> DrivingInfo:
    base = {"vehicle_id": "v", "name": "v", "plate": None, "company_id": "c", "seats": None}
    base |= {"hazmat": False, "tanker": False}
    return DrivingInfo(kind=kind, gvw_t=gvw, **base | extra)


@pytest.mark.parametrize(
    ("vehicle", "needed"),
    [
        (info("van", 3.5), "B"),
        (info("van", 3.0, trailer_kind="trailer", trailer_gvw_t=1.5), "BE"),
        (info("rigid", 7.0), "C1"),
        (info("rigid", 18), "C"),
        (info("rigid", 18, trailer_kind="trailer", trailer_gvw_t=10), "CE"),
        (info("tractor", 18, trailer_kind="semitrailer", trailer_gvw_t=24), "CE"),
        (info("bus", 5, seats=12), "D1"),
        (info("bus", 18, seats=50), "D"),
        (info("semitrailer", 24), None),
    ],
)
def test_required_category(vehicle, needed):
    assert rules.required_category(vehicle) == needed


def test_categories_cover_lower_and_adr():
    assert rules.covers(["CE"], "C1E") and rules.covers(["C"], "B")
    assert not rules.covers(["C"], "CE") and not rules.covers(["D"], "C")

    class Card:
        license_categories = ["CE"]
        adr_until = date.today() + timedelta(days=100)
        adr_tank = False
        license_until = medical_until = psych_until = attestation_until = None
        code95_until = card_until = card_download_until = None

    tanker = info("tractor", 18, hazmat=True, tanker=True)
    assert len(rules.problems(Card(), tanker, date.today())) == 1  # bez cystern
    Card.adr_tank = True
    assert rules.problems(Card(), tanker, date.today()) == []
    Card.code95_until = date.today() - timedelta(days=1)
    assert len(rules.problems(Card(), tanker, date.today())) == 1


def test_dashboard_shows_assigned_drivers_and_their_deadlines(client, company):
    today = date.today()
    body = {
        "company_id": company["id"],
        "name": "Jan Kowalski",
        "member_id": member_id(client, company["id"], "jan"),
        "medical_until": (today - timedelta(days=2)).isoformat(),
        "card_until": (today + timedelta(days=20)).isoformat(),
    }
    driver = client.post("/api/m/drivers/drivers", json=body, headers=as_user("olek")).json()
    client.post("/api/m/drivers/drivers", json=body | {"name": "Bez konta", "member_id": None},
                headers=as_user("olek"))  # fmt: skip
    assigned = client.post(
        f"/api/m/drivers/drivers/{driver['id']}/assign",
        json={"vehicle_id": company["tractor"]},
        headers=as_user("olek"),
    )
    assert assigned.status_code == 200, assigned.text
    params = {"company_id": company["id"]}
    overview = client.get("/api/dashboard/overview", params=params, headers=as_user("olek")).json()
    kpis = {k["key"]: k for k in overview["kpis"]}
    assert (kpis["drivers.assigned"]["value"], kpis["drivers.assigned"]["total"]) == (1, 2)
    assert (kpis["drivers.deadlines"]["value"], kpis["drivers.deadlines"]["tone"]) == (4, "error")
    alerts = client.get("/api/dashboard/alerts", params=params, headers=as_user("olek")).json()
    mine = [
        a for a in alerts if a["source"] == "drivers" and a["data"]["driver_name"] == "Jan Kowalski"
    ]
    assert [(a["data"]["field"], a["severity"]) for a in mine] == [
        ("medical_until", "critical"),
        ("card_until", "info"),
    ]
    assert mine[0]["actions"] == ["acknowledge", "message_driver"]
    sent = client.post(
        f"/api/dashboard/alerts/{mine[0]['id']}/action",
        json={"company_id": company["id"], "action": "message_driver", "text": "Badania!"},
        headers=as_user("olek"),
    )
    assert sent.status_code == 200
    inbox = client.get("/api/me/messages", headers=as_user("jan")).json()["items"]
    assert any(m["kind"] == "dispatch_note" and m["data"]["text"] == "Badania!" for m in inbox)
