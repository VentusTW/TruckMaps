import asyncio
import json
from datetime import UTC, date, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from truckmaps.core import dashboard
from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.config import Settings
from truckmaps.core.vehicles import VehicleProfile
from truckmaps.sdk import (
    DASHBOARD_FEED,
    CoreContext,
    DashboardAlert,
    DashboardKpi,
    DashboardPart,
    Module,
    Principal,
)

TRACTOR = {
    "name": "MAN TGX",
    "kind": "tractor",
    "plate": "WI 4022P",
    "height_m": 4.0,
    "width_m": 2.55,
    "length_m": 6.0,
    "gvw_t": 18,
    "axle_load_t": 11.5,
    "axle_count": 2,
}
SEMITRAILER = TRACTOR | {"name": "Krone", "kind": "semitrailer", "plate": "WN 9024X", "gvw_t": 24}


class FakeVerifier:
    def verify(self, token: str) -> Principal:
        if not token.startswith("user-"):
            raise InvalidToken(token)
        subject = token.removeprefix("user-")
        return Principal(subject=subject, claims={"name": subject.title()})


def as_user(subject: str) -> dict:
    return {"Authorization": f"Bearer user-{subject}"}


class FeedModule(Module):
    """Moduł testowy z częścią pulpitu (i drugi, który się psuje)."""

    def __init__(self, module_id: str, broken: bool = False) -> None:
        self.id = module_id
        self.name = module_id
        self.version = "1.0.0"
        self.requires_core = ">=0.1,<1.0"
        self.broken = broken

    def register(self, ctx: CoreContext) -> None:
        broken = self.broken

        class Feed:
            def collect(self, db, company_id: str, today: date) -> DashboardPart:
                if broken:
                    raise RuntimeError("awaria modułu")
                return DashboardPart(
                    kpis=[DashboardKpi(key="extra.count", value=3, order=1)],
                    alerts=[
                        DashboardAlert(
                            id=f"extra:{company_id}", kind="extra.alert", severity="critical"
                        )
                    ],
                )

        ctx.extensions.provide(DASHBOARD_FEED, Feed())


@pytest.fixture
def client(database):
    app = create_app(
        Settings(dev_grant_all=True),
        modules=[FeedModule("extra"), FeedModule("broken", broken=True)],
        token_verifier=FakeVerifier(),
        database=database,
        router=object(),
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
def fleet(client, database):
    company_id = client.post(
        "/api/companies", json={"name": "Trans-Miś"}, headers=as_user("olek")
    ).json()["id"]
    join(client, company_id, "jan", "driver")
    join(client, company_id, "ewa", "dispatcher")
    today = date.today()
    tractor = client.post(
        "/api/vehicles",
        json=TRACTOR
        | {"company_id": company_id, "inspection_until": (today - timedelta(days=1)).isoformat()},
        headers=as_user("olek"),
    ).json()
    spare = client.post(
        "/api/vehicles",
        json=TRACTOR | {"name": "Volvo FH", "plate": "WZ 7701L", "company_id": company_id},
        headers=as_user("olek"),
    ).json()
    trailer = client.post(
        "/api/vehicles",
        json=SEMITRAILER
        | {"company_id": company_id, "insurance_until": (today + timedelta(days=20)).isoformat()},
        headers=as_user("olek"),
    ).json()
    members = client.get(f"/api/companies/{company_id}", headers=as_user("olek")).json()["members"]
    jan = next(m["id"] for m in members if m["display_name"] == "Jan")
    assert (
        client.put(
            f"/api/vehicles/{tractor['id']}/driver",
            json={"member_id": jan},
            headers=as_user("olek"),
        ).status_code
        == 200
    )
    with database.session() as db:
        vehicle = db.get(VehicleProfile, tractor["id"])
        vehicle.in_use_by = "jan"
        vehicle.in_use_until = datetime.now(UTC) + timedelta(hours=5)
        db.get(VehicleProfile, spare["id"]).repair_reported = True
        db.commit()
    now = datetime.now(UTC)
    trip = {
        "started_at": (now - timedelta(minutes=90)).isoformat(),
        "ended_at": now.isoformat(),
        "distance_km": 110,
        "planned_km": 100,
        "cost_amount": 250.5,
        "cost_currency": "PLN",
    }
    assert (
        client.post(
            f"/api/vehicles/{tractor['id']}/trips", json=trip, headers=as_user("jan")
        ).status_code
        == 201
    )
    return {
        "id": company_id,
        "tractor": tractor["id"],
        "spare": spare["id"],
        "trailer": trailer["id"],
    }


def kpi(overview: dict, key: str) -> dict:
    return next(k for k in overview["kpis"] if k["key"] == key)


def test_overview_counts_fleet_trips_costs_and_module_parts(client, fleet):
    response = client.get(
        "/api/dashboard/overview", params={"company_id": fleet["id"]}, headers=as_user("ewa")
    )
    assert response.status_code == 200
    overview = response.json()
    assert (overview["company_name"], overview["user_name"], overview["role"]) == (
        "Trans-Miś",
        "Ewa",
        "dispatcher",
    )
    assert overview["telematics"] is False
    assert overview["sources"] == ["core", "extra"]  # moduł z błędem nie psuje pulpitu
    assert (kpi(overview, "fleet.active")["value"], kpi(overview, "fleet.active")["total"]) == (
        1,
        2,
    )
    assert (
        kpi(overview, "fleet.available")["value"] == 0
    )  # jeden w trasie, drugi ze zgłoszoną usterką
    assert kpi(overview, "fleet.service")["value"] == 1
    # 3 pojazdy: przeterminowany przegląd ciągnika → 2 z 3 sprawne.
    assert (
        kpi(overview, "fleet.health").items()
        >= {"value": 66.7, "unit": "%", "tone": "error"}.items()
    )
    assert kpi(overview, "fleet.deadlines").items() >= {"value": 2, "tone": "error"}.items()
    assert kpi(overview, "trips.today")["value"] == 1
    assert kpi(overview, "trips.km_today").items() >= {"value": 110, "unit": "km"}.items()
    assert kpi(overview, "costs.today").items() >= {"value": 250.5, "unit": "PLN"}.items()
    assert (
        kpi(overview, "trips.plan_deviation").items() >= {"value": 10.0, "tone": "warning"}.items()
    )
    assert kpi(overview, "extra.count")["source"] == "extra"
    assert overview["kpis"][0]["key"] == "extra.count"  # kolejność wg ``order``
    assert overview["alert_counts"] == {"critical": 2, "warning": 1, "info": 1}


def test_alerts_sorted_with_vehicle_and_driver(client, fleet):
    alerts = client.get(
        "/api/dashboard/alerts", params={"company_id": fleet["id"]}, headers=as_user("olek")
    ).json()
    assert [(a["kind"], a["severity"]) for a in alerts] == [
        ("vehicle_due", "critical"),
        ("extra.alert", "critical"),
        ("vehicle_reported", "warning"),
        ("vehicle_due", "info"),
    ]
    overdue = alerts[0]
    assert overdue["data"].items() >= {"field": "inspection_until", "overdue": True}.items()
    assert (overdue["vehicle_name"], overdue["plate"], overdue["driver_name"]) == (
        "MAN TGX",
        "WI 4022P",
        "Jan",
    )
    assert overdue["actions"] == ["acknowledge", "message_driver"]
    assert alerts[1]["source"] == "extra"
    assert alerts[2]["actions"] == ["acknowledge"]  # bez kierowcy – tylko „obsłużone”


def test_access_only_for_owner_and_dispatcher(client, fleet):
    params = {"company_id": fleet["id"]}
    assert (
        client.get("/api/dashboard/overview", params=params, headers=as_user("jan")).status_code
        == 403
    )
    assert (
        client.get("/api/dashboard/alerts", params=params, headers=as_user("obcy")).status_code
        == 404
    )
    assert client.get("/api/dashboard/overview", params=params).status_code == 401
    body = {"company_id": fleet["id"], "action": "acknowledge"}
    assert (
        client.post("/api/dashboard/alerts/x/action", json=body, headers=as_user("jan")).status_code
        == 403
    )


def test_message_driver_once_with_audit_and_reopen(client, fleet):
    params = {"company_id": fleet["id"]}
    alert = client.get("/api/dashboard/alerts", params=params, headers=as_user("ewa")).json()[0]
    url = f"/api/dashboard/alerts/{alert['id']}/action"
    body = {"company_id": fleet["id"], "action": "message_driver"}
    assert client.post(url, json=body, headers=as_user("ewa")).status_code == 422  # bez treści
    sent = client.post(url, json=body | {"text": " Zjedź na przegląd "}, headers=as_user("ewa"))
    assert sent.status_code == 200
    assert sent.json().items() >= {"action": "message_driver", "duplicate": False}.items()
    assert sent.json()["handled"].items() >= {"by_name": "Ewa", "note": "Zjedź na przegląd"}.items()
    # Podwójne kliknięcie – nic nie powtórzone.
    again = client.post(url, json=body | {"text": "Zjedź na przegląd"}, headers=as_user("ewa"))
    assert again.json()["duplicate"] is True

    inbox = client.get("/api/me/messages", headers=as_user("jan")).json()
    notes = [m for m in inbox["items"] if m["kind"] == "dispatch_note"]
    assert len(notes) == 1
    assert notes[0]["sender_name"] == "Ewa"
    assert (
        notes[0]["data"].items()
        >= {
            "text": "Zjedź na przegląd",
            "vehicle_name": "MAN TGX",
            "alert_kind": "vehicle_due",
        }.items()
    )

    ids = [
        a["id"]
        for a in client.get("/api/dashboard/alerts", params=params, headers=as_user("ewa")).json()
    ]
    assert alert["id"] not in ids
    handled = client.get(
        "/api/dashboard/alerts", params=params | {"include_handled": True}, headers=as_user("ewa")
    ).json()
    assert (
        next(a for a in handled if a["id"] == alert["id"])["handled"]["action"] == "message_driver"
    )

    assert client.delete(url, params=params, headers=as_user("olek")).status_code == 204
    assert client.delete(url, params=params, headers=as_user("olek")).status_code == 404
    ids = [
        a["id"]
        for a in client.get("/api/dashboard/alerts", params=params, headers=as_user("ewa")).json()
    ]
    assert alert["id"] in ids


def test_action_errors(client, fleet):
    params = {"company_id": fleet["id"]}
    alerts = client.get("/api/dashboard/alerts", params=params, headers=as_user("ewa")).json()
    reported = next(a for a in alerts if a["kind"] == "vehicle_reported")
    body = {"company_id": fleet["id"], "action": "message_driver", "text": "?"}
    response = client.post(
        f"/api/dashboard/alerts/{reported['id']}/action", json=body, headers=as_user("ewa")
    )
    assert response.status_code == 422
    unknown = client.post(
        "/api/dashboard/alerts/vehicle:due:nope/action",
        json=body | {"action": "acknowledge"},
        headers=as_user("ewa"),
    )
    assert unknown.status_code == 404
    bad = client.post(
        f"/api/dashboard/alerts/{reported['id']}/action",
        json=body | {"action": "reset_reefer"},
        headers=as_user("ewa"),
    )
    assert bad.status_code == 422  # brak downlinku telematycznego – akcji nie ma
    ok = client.post(
        f"/api/dashboard/alerts/{reported['id']}/action",
        json=body | {"action": "acknowledge"},
        headers=as_user("ewa"),
    )
    assert ok.json()["handled"]["action"] == "acknowledge"


def test_stream_sends_snapshot(client, fleet):
    params = {"company_id": fleet["id"], "once": True}
    with client.stream(
        "GET", "/api/dashboard/stream", params=params, headers=as_user("ewa")
    ) as response:
        assert response.status_code == 200
        assert response.headers["content-type"].startswith("text/event-stream")
        body = "".join(response.iter_text())
    event, data = body.strip().split("\n", 1)
    assert event == "event: snapshot"
    state = json.loads(data.removeprefix("data: "))
    assert state["overview"]["company_id"] == fleet["id"]
    assert len(state["alerts"]) == 4
    assert (
        client.get("/api/dashboard/stream", params=params, headers=as_user("jan")).status_code
        == 403
    )


def test_stream_sends_only_changes():
    states = iter(
        [
            {"overview": {"generated_at": 1, "kpis": [1]}, "alerts": []},
            {"overview": {"generated_at": 2, "kpis": [1]}, "alerts": []},
            {"overview": {"generated_at": 3, "kpis": [2]}, "alerts": []},
        ]
    )
    ticks = iter([False, False, False, True])

    async def compute():
        return next(states)

    async def disconnected():
        return next(ticks)

    async def run():
        return [e async for e in dashboard.stream_events(compute, 0, disconnected)]

    events = asyncio.run(run())
    assert [e.split("\n")[0] for e in events] == ["event: snapshot", ": ping", "event: snapshot"]


def test_screen_empty_then_demo_data(client, fleet, database):
    from truckmaps.core.dashboard_demo import STITCH, main

    url = f"/api/dashboard/screen?company_id={fleet['id']}"
    empty = client.get(url, headers=as_user("ewa")).json()
    assert empty["company_name"] == "Trans-Miś"
    assert empty["role"] == "dispatcher"
    assert empty["screen"] is None
    # Pulpit główny widzi każdy członek firmy; obcy – nie.
    assert client.get(url, headers=as_user("jan")).status_code == 200
    assert client.get(url, headers=as_user("obcy")).status_code in (403, 404)

    main(["--company", "trans-miś"], database=database)
    screen = client.get(url, headers=as_user("ewa")).json()
    assert screen["screen"] == STITCH
    assert screen["updated_at"] is not None
    main(["--company", fleet["id"], "--remove"], database=database)
    assert client.get(url, headers=as_user("ewa")).json()["screen"] is None


def test_demo_fleet_is_regular_vehicles(client, fleet, database):
    from truckmaps.core.dashboard_demo import main

    main(["--company", fleet["id"], "--vehicles"], database=database)
    main(["--company", fleet["id"], "--vehicles"], database=database)  # powtórka – bez duplikatów
    vehicles = client.get("/api/vehicles", headers=as_user("olek")).json()
    demo = {v["plate"]: v for v in vehicles if (v.get("vin") or "").startswith("DEMO")}
    assert len(demo) == 10
    volvo = demo["WI 4022P"]
    assert volvo["in_use"] is True
    assert volvo["driver_name"] == "Janusz Bogucki"
    assert volvo["trailer_name"] == "Schmitz S.CS MEGA"
    assert demo["WI 1099R"]["in_repair"] is True
    assert demo["WI 8812M"]["assigned_driver_name"] == "Paweł Wiśniewski"
    # Kartoteka Kierowców i zlecenia Serwisu – tylko gdy oba moduły są zainstalowane
    # (testy samego rdzenia i pojedynczych modułów ich nie mają).
    from sqlalchemy import select

    from truckmaps.core.trips import VehicleTrip

    try:
        from truckmaps_drivers.module import Driver
        from truckmaps_service.module import ServiceOrder
    except ImportError:
        Driver = ServiceOrder = None
    if Driver is not None and ServiceOrder is not None:
        Driver.__table__.create(database.engine, checkfirst=True)
        ServiceOrder.__table__.create(database.engine, checkfirst=True)
        main(["--company", fleet["id"], "--vehicles"], database=database)
        with database.session() as db:
            orders = list(db.scalars(select(ServiceOrder)))
            assert len(orders) == 13
            assert any(o.status == "done" and o.parts and o.labour_hours for o in orders)
            assert len(list(db.scalars(select(VehicleTrip)))) >= 260
            bogucki = db.scalar(select(Driver).where(Driver.subject == "demo-janusz-bogucki"))
            assert bogucki is not None and bogucki.adr_tank
            assert "C+E" in bogucki.license_categories

    main(["--company", fleet["id"], "--vehicles", "--remove"], database=database)
    vehicles = client.get("/api/vehicles", headers=as_user("olek")).json()
    assert not [v for v in vehicles if (v.get("vin") or "").startswith("DEMO")]
