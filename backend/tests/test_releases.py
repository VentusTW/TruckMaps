import pytest
from fastapi.testclient import TestClient

from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.config import Settings
from truckmaps.core.releases import main, version_key
from truckmaps.sdk import Principal


class FakeVerifier:
    def verify(self, token: str) -> Principal:
        if not token.startswith("user-"):
            raise InvalidToken(token)
        return Principal(subject=token.removeprefix("user-"))


@pytest.fixture
def client(database):
    app = create_app(Settings(), modules=[], token_verifier=FakeVerifier(), database=database)
    with TestClient(app) as client:
        yield client


def release(database, *args: str) -> None:
    main(list(args), database=database)


def check(client, version="0.1.0", who="ola", platform="windows", language="pl"):
    response = client.post(
        "/api/updates/check",
        json={
            "platform": platform,
            "installed": [{"kind": "app", "name": "truckmaps", "version": version}],
        },
        headers={"Authorization": f"Bearer user-{who}", "Accept-Language": language},
    )
    assert response.status_code == 200, response.json()
    return [(u["action"], u["version"]) for u in response.json()], response.json()


def add(database, version, *extra):
    release(
        database,
        "add",
        "--platform",
        "windows",
        version,
        "--url",
        f"https://example.test/truckmaps-{version}.zip",
        "--size",
        "52428800",
        *extra,
    )


def test_version_order_is_numeric():
    assert version_key("0.10.0") > version_key("0.9.3")
    assert version_key("1.2.0+15") == version_key("1.2.0")


def test_newer_release_with_notes_in_request_language(client, database):
    add(database, "0.2.0", "--notes", "pl=Konto i firmy", "--notes", "en=Accounts and companies")
    add(database, "0.1.5")

    found, body = check(client)
    assert found == [("update", "0.2.0")]
    assert (body[0]["notes"], body[0]["size_bytes"]) == ("Konto i firmy", 52428800)
    assert check(client, language="en")[1][0]["notes"] == "Accounts and companies"
    assert check(client, version="0.2.0")[0] == []
    assert check(client, platform="android")[0] == []


def test_staged_rollout_pause_and_withdraw(client, database):
    add(database, "0.1.1")
    add(database, "0.2.0", "--rollout", "0")
    users = [f"u{i}" for i in range(40)]
    assert {check(client, who=u)[0][0] for u in users} == {("update", "0.1.1")}

    release(database, "rollout", "--platform", "windows", "0.2.0", "50")
    got = {u: check(client, who=u)[0][0][1] for u in users}
    assert set(got.values()) == {"0.1.1", "0.2.0"}
    # Ten sam użytkownik za każdym razem w tej samej części.
    assert all(check(client, who=u)[0][0][1] == v for u, v in got.items())

    release(database, "pause", "--platform", "windows", "0.2.0")
    assert {check(client, who=u)[0][0] for u in users} == {("update", "0.1.1")}
    # Kto ma wstrzymane wydanie, zostaje przy nim.
    assert check(client, version="0.2.0")[0] == []

    release(database, "withdraw", "--platform", "windows", "0.2.0")
    assert check(client, version="0.2.0")[0] == [("rollback", "0.1.1")]


def test_unknown_release_and_login_required(client, database):
    with pytest.raises(SystemExit, match="Nie znaleziono wydania 9.9.9."):
        release(database, "pause", "9.9.9")
    assert (
        client.post("/api/updates/check", json={"platform": "web", "installed": []}).status_code
        == 401
    )
