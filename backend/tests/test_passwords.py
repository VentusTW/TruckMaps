import httpx
import pytest
from fastapi.testclient import TestClient

from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.config import Settings
from truckmaps.core.passwords import RESET_LIMIT, WrongPassword, ZitadelPasswords, weak_password
from truckmaps.sdk import Principal


class FakeVerifier:
    def verify(self, token: str) -> Principal:
        if not token.startswith("user-"):
            raise InvalidToken(token)
        return Principal(subject=token.removeprefix("user-"))


class FakePasswords:
    def __init__(self) -> None:
        self.resets: list[str] = []
        self.passwords = {"ola": "Stare-haslo1"}

    def request_reset(self, email: str) -> None:
        self.resets.append(email)

    def change(self, subject: str, current: str, new: str) -> None:
        if self.passwords.get(subject) != current:
            raise WrongPassword(subject)
        self.passwords[subject] = new


@pytest.fixture
def passwords():
    return FakePasswords()


@pytest.fixture
def client(passwords):
    app = create_app(
        Settings(), modules=[], token_verifier=FakeVerifier(), password_service=passwords
    )
    with TestClient(app) as client:
        yield client


OLA = {"Authorization": "Bearer user-ola"}


def test_reset_link_answer_does_not_reveal_accounts_and_is_limited(client, passwords):
    for _ in range(RESET_LIMIT + 2):
        response = client.post("/api/auth/password-reset", json={"email": " Ola@Firma.PL "})
        assert response.status_code == 202
        assert response.json()["detail"].startswith("Jeśli to konto istnieje")
    assert passwords.resets == ["ola@firma.pl"] * RESET_LIMIT
    assert client.post("/api/auth/password-reset", json={"email": "bez-malpy"}).status_code == 422


def test_change_password_checks_current_and_strength(client, passwords):
    body = {"current_password": "Stare-haslo1", "new_password": "krotkie"}
    weak = client.post("/api/me/password", json=body, headers=OLA)
    assert (weak.status_code, weak.json()["detail"][:13]) == (422, "Hasło musi mi")

    body = {"current_password": "zle", "new_password": "Nowe-haslo2"}
    wrong = client.post("/api/me/password", json=body, headers=OLA)
    assert (wrong.status_code, wrong.json()["detail"]) == (400, "Obecne hasło jest nieprawidłowe.")

    body = {"current_password": "Stare-haslo1", "new_password": "Nowe-haslo2"}
    assert client.post("/api/me/password", json=body, headers=OLA).status_code == 204
    assert passwords.passwords["ola"] == "Nowe-haslo2"
    assert client.post("/api/me/password", json=body).status_code == 401


def test_without_service_password_endpoints_say_so():
    app = create_app(Settings(), modules=[], token_verifier=FakeVerifier())
    with TestClient(app) as client:
        response = client.post("/api/auth/password-reset", json={"email": "a@b.pl"})
    assert response.status_code == 503


def test_weak_password_rules():
    assert weak_password("Abcdef1")
    assert weak_password("abcdefg1!")
    assert not weak_password("Abcdefg1!")


def test_zitadel_calls():
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append((request.method, request.url.path, request.read().decode()))
        if request.url.path == "/v2/users":
            return httpx.Response(200, json={"result": [{"userId": "u1"}]})
        if request.url.path == "/v2/users/u2/password":
            return httpx.Response(400, json={"code": 3, "message": "invalid"})
        return httpx.Response(200, json={})

    client = httpx.Client(base_url="http://zitadel.test", transport=httpx.MockTransport(handler))
    zitadel = ZitadelPasswords("http://zitadel.test", "token", client)
    zitadel.request_reset("ola@firma.pl")
    zitadel.change("u1", "Stare-haslo1", "Nowe-haslo2")
    with pytest.raises(WrongPassword):
        zitadel.change("u2", "zle", "Nowe-haslo2")

    assert [c[1] for c in calls] == [
        "/v2/users",
        "/v2/users/u1/password_reset",
        "/v2/users/u1/password",
        "/v2/users/u2/password",
    ]
    assert '"currentPassword":"Stare-haslo1"' in calls[2][2].replace(" ", "")
