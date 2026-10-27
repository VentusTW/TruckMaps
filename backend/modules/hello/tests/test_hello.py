from fastapi.testclient import TestClient

from truckmaps.core.app import create_app
from truckmaps.core.config import Settings
from truckmaps_hello.module import HelloModule


def test_greeting_lists_active_modules_after_startup():
    app = create_app(Settings(dev_grant_all=True), modules=[HelloModule()])

    with TestClient(app) as client:
        body = client.get("/api/m/hello/greeting").json()

    assert body["message"] == "Witaj w TruckMaps!"
    assert body["active_modules"] == ["hello"]


def test_cost_uses_core_default_provider():
    app = create_app(Settings(dev_grant_all=True), modules=[HelloModule()])

    with TestClient(app) as client:
        body = client.get("/api/m/hello/cost", params={"distance_km": 250}).json()

    assert body == {"eur": 250.0}


def test_requires_license():
    settings = Settings(licenses={"acc-1": frozenset({"hello"})})
    app = create_app(settings, modules=[HelloModule()])

    with TestClient(app) as client:

        def status_for(account: str | None) -> int:
            headers = {"X-Account-Id": account} if account else {}
            return client.get("/api/m/hello/greeting", headers=headers).status_code

        assert status_for(None) == 402
        assert status_for("acc-2") == 402
        assert status_for("acc-1") == 200


def test_discovered_through_entry_point():
    app = create_app(Settings(dev_grant_all=True))

    assert "hello" in app.state.modules.active
