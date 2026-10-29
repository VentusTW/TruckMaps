import time
from urllib.parse import parse_qs, urlparse

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

from truckmaps.core import devlogin
from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken, OidcProvider
from truckmaps.core.config import Settings
from truckmaps.sdk import Module

ISSUER = "http://idp.test"
CLIENT_ID = "client-1"
PROJECT_ID = "project-1"
KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OTHER_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
METADATA = {
    "issuer": ISSUER,
    "authorization_endpoint": f"{ISSUER}/oauth/v2/authorize",
    "token_endpoint": f"{ISSUER}/oauth/v2/token",
    "end_session_endpoint": f"{ISSUER}/oidc/v1/end_session",
    "jwks_uri": f"{ISSUER}/oauth/v2/keys",
}


class StaticJwks:
    def get_signing_key_from_jwt(self, token: str):
        return type("Key", (), {"key": KEY.public_key()})()


def make_token(key=KEY, **overrides) -> str:
    now = int(time.time())
    claims = {
        "iss": ISSUER,
        "sub": "user-42",
        "aud": [CLIENT_ID, PROJECT_ID],
        "iat": now,
        "exp": now + 300,
        "urn:zitadel:iam:user:resourceowner:id": "org-7",
    } | overrides
    return jwt.encode(claims, key, algorithm="RS256")


@pytest.fixture
def provider() -> OidcProvider:
    provider = OidcProvider(ISSUER, CLIENT_ID, project_id=PROJECT_ID, jwks_client=StaticJwks())
    provider.__dict__["metadata"] = METADATA
    return provider


def test_valid_token_gives_principal(provider):
    principal = provider.verify(make_token())

    assert principal.subject == "user-42"
    assert principal.organization_id == "org-7"


@pytest.mark.parametrize(
    "token",
    [
        make_token(exp=int(time.time()) - 10),
        make_token(aud="someone-else"),
        make_token(iss="http://evil.test"),
        make_token(key=OTHER_KEY),
    ],
    ids=["expired", "wrong-audience", "wrong-issuer", "wrong-signature"],
)
def test_invalid_tokens_are_rejected(provider, token):
    with pytest.raises(InvalidToken):
        provider.verify(token)


def test_me_requires_valid_token(provider):
    app = create_app(Settings(), modules=[], token_verifier=provider)

    with TestClient(app) as client:
        assert client.get("/api/me").status_code == 401
        assert client.get("/api/me", headers={"Authorization": "Bearer junk"}).status_code == 401
        me = client.get("/api/me", headers={"Authorization": f"Bearer {make_token()}"})

    assert me.json() == {"subject": "user-42", "organization_id": "org-7"}


def test_token_rejected_when_login_not_configured():
    app = create_app(Settings(), modules=[])

    with TestClient(app) as client:
        response = client.get("/api/me", headers={"Authorization": f"Bearer {make_token()}"})

    assert response.status_code == 401


def dev_login_app(provider, token_handler):
    app = create_app(Settings(), modules=[], token_verifier=provider)
    http = httpx.Client(transport=httpx.MockTransport(token_handler))
    app.include_router(devlogin.build_router(provider, "http://testserver", http=http))
    return app


def test_dev_login_full_flow(provider):
    def token_endpoint(request: httpx.Request) -> httpx.Response:
        form = parse_qs(request.content.decode())
        assert form["code"] == ["the-code"]
        assert form["code_verifier"]
        nonce = devlogin.decode_flow(client.cookies[devlogin.FLOW_COOKIE])["nonce"]
        id_token = make_token(aud=CLIENT_ID, nonce=nonce, email="anna@example.test")
        return httpx.Response(200, json={"access_token": make_token(), "id_token": id_token})

    app = dev_login_app(provider, token_endpoint)
    with TestClient(app, follow_redirects=False) as client:
        assert "Zaloguj się e-mailem" in client.get("/").text

        assert client.get("/planer").status_code == 303  # bez logowania wraca na /

        login = client.get("/auth/login")
        query = parse_qs(urlparse(login.headers["location"]).query)
        assert query["client_id"] == [CLIENT_ID]
        assert query["code_challenge_method"] == ["S256"]

        callback = client.get(
            "/auth/callback", params={"code": "the-code", "state": query["state"][0]}
        )
        assert callback.status_code == 303

        page = client.get("/").text
        assert "anna@example.test" in page
        assert "Wyloguj" in page

        planner = client.get("/planer")
        assert planner.status_code == 200
        assert "Planer trasy" in planner.text
        assert "__ACCESS_TOKEN__" not in planner.text


def test_dev_login_rejects_wrong_state(provider):
    app = dev_login_app(provider, lambda request: httpx.Response(500))

    with TestClient(app, follow_redirects=False) as client:
        client.get("/auth/login")
        response = client.get("/auth/callback", params={"code": "x", "state": "forged"})

    assert response.status_code == 303
    assert "error=" in response.headers["location"]


def test_app_login_returns_to_loopback_with_one_time_code(provider):
    access = make_token()

    def token_endpoint(request: httpx.Request) -> httpx.Response:
        form = parse_qs(request.content.decode())
        if form["grant_type"] == ["refresh_token"]:
            if form["refresh_token"] != ["refresh-1"]:
                return httpx.Response(400, json={"error": "invalid_grant"})
            return httpx.Response(200, json={"access_token": access, "expires_in": 900})
        nonce = devlogin.decode_flow(client.cookies[devlogin.FLOW_COOKIE])["nonce"]
        id_token = make_token(aud=CLIENT_ID, nonce=nonce, name="Anna Kowalska")
        return httpx.Response(
            200,
            json={
                "access_token": access,
                "id_token": id_token,
                "expires_in": 1800,
                "refresh_token": "refresh-1",
            },
        )

    app = dev_login_app(provider, token_endpoint)
    with TestClient(app, follow_redirects=False) as client:
        refused = client.get("/auth/login", params={"app": "http://evil.test:8080/callback"})
        assert "error=" in refused.headers["location"]

        login = client.get("/auth/login", params={"app": "http://127.0.0.1:53123/callback"})
        state = parse_qs(urlparse(login.headers["location"]).query)["state"][0]
        callback = client.get("/auth/callback", params={"code": "the-code", "state": state})

        back = urlparse(callback.headers["location"])
        assert (back.hostname, back.port, back.path) == ("127.0.0.1", 53123, "/callback")
        code = parse_qs(back.query)["code"][0]
        assert access not in callback.headers["location"]  # token nie trafia do adresu

        token = client.post("/auth/app/token", json={"code": code})
        assert token.json() == {
            "access_token": access,
            "expires_in": 1800,
            "name": "Anna Kowalska",
            "refresh_token": "refresh-1",
        }
        assert "offline_access" in parse_qs(urlparse(login.headers["location"]).query)["scope"][0]
        # Kod jest jednorazowy.
        assert client.post("/auth/app/token", json={"code": code}).status_code == 400

        refreshed = client.post("/auth/app/refresh", json={"refresh_token": "refresh-1"})
        assert refreshed.json() == {
            "access_token": access,
            "expires_in": 900,
            "name": "",
            "refresh_token": "refresh-1",
        }
        stale = client.post("/auth/app/refresh", json={"refresh_token": "stary"})
        assert stale.status_code == 401


class HelloModule(Module):
    id = "hello"
    name = "Hello (moduł testowy)"
    version = "0.1.0"
    requires_core = ">=0.1,<1.0"

    def register(self, ctx) -> None:
        pass


def test_my_modules_show_access(provider):
    settings = Settings(licenses={"user-42": frozenset({"hello"})})
    app = create_app(settings, modules=[HelloModule()], token_verifier=provider)
    with TestClient(app) as client:
        mine = client.get("/api/me/modules", headers={"Authorization": f"Bearer {make_token()}"})
        other = make_token(sub="user-2")
        theirs = client.get("/api/me/modules", headers={"Authorization": f"Bearer {other}"})

    assert mine.json() == [
        {"id": "hello", "name": "Hello (moduł testowy)", "version": "0.1.0", "granted": True}
    ]
    assert theirs.json()[0]["granted"] is False
