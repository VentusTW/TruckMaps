from fastapi.testclient import TestClient

from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.config import Settings
from truckmaps.sdk import Principal
from truckmaps_hello.module import HelloModule


class FakeVerifier:
    """Token ``user-<id>`` oznacza użytkownika ``<id>``."""

    def verify(self, token: str) -> Principal:
        if not token.startswith("user-"):
            raise InvalidToken(token)
        return Principal(subject=token.removeprefix("user-"))


def bearer(subject: str) -> dict:
    return {"Authorization": f"Bearer user-{subject}"}


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


def test_requires_login_and_license():
    settings = Settings(licenses={"anna": frozenset({"hello"})})
    app = create_app(settings, modules=[HelloModule()], token_verifier=FakeVerifier())

    with TestClient(app) as client:
        assert client.get("/api/m/hello/greeting").status_code == 401
        assert client.get("/api/m/hello/greeting", headers=bearer("bob")).status_code == 402
        assert client.get("/api/m/hello/greeting", headers=bearer("anna")).status_code == 200


def test_whoami_returns_logged_in_user():
    settings = Settings(dev_grant_all=True)
    app = create_app(settings, modules=[HelloModule()], token_verifier=FakeVerifier())

    with TestClient(app) as client:
        assert client.get("/api/m/hello/whoami").status_code == 401
        assert client.get("/api/m/hello/whoami", headers=bearer("anna")).json() == {
            "subject": "anna"
        }


def test_discovered_through_entry_point():
    app = create_app(Settings(dev_grant_all=True))

    assert "hello" in app.state.modules.active
