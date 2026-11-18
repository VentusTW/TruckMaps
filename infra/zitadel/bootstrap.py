"""Konfiguruje lokalnego Zitadela dla TruckMaps. Można uruchamiać wielokrotnie.

- projekt "TruckMaps" i aplikacja OIDC "truckmaps-dev" (PKCE, bez sekretu, tokeny JWT),
- wysyłka maili przez Mailpit (http://localhost:8025), domyślnie po polsku,
- wygląd ekranów logowania jak TruckMaps (kolory, logo z ``branding/``, teksty bez „Zitadel”),
- konto techniczne serwera (reset i zmiana hasła, rola ORG_USER_MANAGER),
- zapisuje TRUCKMAPS_OIDC_* do pliku .env w katalogu głównym repozytorium.

Uruchomienie (po ``docker compose -f infra/docker-compose.yml up -d --wait``):
    .venv\\Scripts\\python infra\\zitadel\\bootstrap.py
"""

import sys
from pathlib import Path

import httpx

ISSUER = "http://localhost:8080"
PUBLIC_URL = "http://localhost:8000"
PROJECT_NAME = "TruckMaps"
APP_NAME = "truckmaps-dev"
SERVER_USER = "truckmaps-server"

REPO = Path(__file__).resolve().parents[2]
PAT_FILE = REPO / "infra" / "data" / "zitadel-bootstrap" / "admin.pat"
ENV_FILE = REPO / ".env"

OIDC_APP = {
    "name": APP_NAME,
    "redirectUris": [f"{PUBLIC_URL}/auth/callback", "truckmaps://auth/callback"],
    "postLogoutRedirectUris": [f"{PUBLIC_URL}/", "truckmaps://auth/logout"],
    "responseTypes": ["OIDC_RESPONSE_TYPE_CODE"],
    "grantTypes": ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"],
    # Aplikacja natywna z PKCE: bez sekretu, jak docelowa aplikacja Flutter.
    "appType": "OIDC_APP_TYPE_NATIVE",
    "authMethodType": "OIDC_AUTH_METHOD_TYPE_NONE",
    "accessTokenType": "OIDC_TOKEN_TYPE_JWT",
    "idTokenUserinfoAssertion": True,
    # Zezwala na http://localhost w adresach przekierowania – tylko do rozwoju.
    "devMode": True,
}

SMTP = {
    "senderAddress": "noreply@truckmaps.localhost",
    "senderName": "TruckMaps",
    "tls": False,
    "host": "mailpit:1025",
    "user": "",
    "password": "",
    "description": "Mailpit (lokalnie)",
}


BRANDING_DIR = Path(__file__).resolve().parent / "branding"

# Kolory ekranów logowania – te same co na stronie TruckMaps (website/assets/css/style.css).
LABEL_POLICY = {
    "primaryColor": "#0f5bd8",
    "backgroundColor": "#f6f8fb",
    "warnColor": "#c2410c",
    "fontColor": "#16202e",
    "primaryColorDark": "#6ea8ff",
    "backgroundColorDark": "#0f1722",
    "warnColorDark": "#f2994a",
    "fontColorDark": "#e8eef7",
    "hideLoginNameSuffix": True,
    "disableWatermark": True,
    "themeMode": "THEME_MODE_AUTO",
}

# Plik → zasób polityki wyglądu (logo i ikona w jasnym i ciemnym motywie).
BRANDING_ASSETS = {
    "logo-light.svg": "logo",
    "logo-dark.svg": "logo/dark",
    "icon.svg": "icon",
    "icon.svg#dark": "icon/dark",
}

# Teksty ekranu logowania, które domyślnie mówią „Zitadel” – w każdym języku aplikacji.
LOGIN_TEXTS = {
    "pl": {
        "common": {"title": "Zaloguj się do TruckMaps"},
        "register": {"description": "Utwórz konto TruckMaps."},
    },
    "en": {
        "common": {"title": "Sign in to TruckMaps"},
        "register": {"description": "Create your TruckMaps account."},
    },
}


def main() -> None:
    if not PAT_FILE.exists():
        sys.exit(f"Brak {PAT_FILE} – najpierw uruchom docker compose (patrz README).")
    client = httpx.Client(
        base_url=ISSUER,
        headers={"Authorization": f"Bearer {PAT_FILE.read_text().strip()}"},
        timeout=30,
    )

    project_id = ensure_project(client)
    client_id = ensure_app(client, project_id)
    ensure_smtp(client)
    # Domyślny język maili i ekranów dla użytkowników bez wybranego języka.
    call(client, "PUT", "/admin/v1/languages/default/pl", {}, allow={400})
    ensure_branding(client)

    server_token = ensure_server_user(client)

    write_env(
        {
            "TRUCKMAPS_OIDC_ISSUER": ISSUER,
            "TRUCKMAPS_OIDC_CLIENT_ID": client_id,
            "TRUCKMAPS_OIDC_PROJECT_ID": project_id,
            "TRUCKMAPS_PUBLIC_URL": PUBLIC_URL,
            **({"TRUCKMAPS_ZITADEL_TOKEN": server_token} if server_token else {}),
        }
    )
    print(f"Projekt {PROJECT_NAME}: {project_id}")
    print(f"Aplikacja {APP_NAME}: client_id={client_id}")
    print(f"Zapisano {ENV_FILE}")
    print("Nowy wygląd logowania: docker compose -f infra/docker-compose.yml restart zitadel-login")


def ensure_project(client: httpx.Client) -> str:
    query = {"nameQuery": {"name": PROJECT_NAME, "method": "TEXT_QUERY_METHOD_EQUALS"}}
    found = call(client, "POST", "/management/v1/projects/_search", {"queries": [query]})
    if found.get("result"):
        return found["result"][0]["id"]
    return call(client, "POST", "/management/v1/projects", {"name": PROJECT_NAME})["id"]


def ensure_app(client: httpx.Client, project_id: str) -> str:
    apps = call(client, "POST", f"/management/v1/projects/{project_id}/apps/_search", {})
    for app in apps.get("result", []):
        if app["name"] == APP_NAME:
            # Aktualizuje konfigurację, gdyby zmieniła się w tym pliku.
            config = {k: v for k, v in OIDC_APP.items() if k != "name"}
            call(
                client,
                "PUT",
                f"/management/v1/projects/{project_id}/apps/{app['id']}/oidc_config",
                config,
                allow={400},  # "nic się nie zmieniło"
            )
            return app["oidcConfig"]["clientId"]
    created = call(client, "POST", f"/management/v1/projects/{project_id}/apps/oidc", OIDC_APP)
    return created["clientId"]


def ensure_server_user(client: httpx.Client) -> str | None:
    """Konto techniczne serwera; nowy token tylko, gdy w .env jeszcze go nie ma."""
    query = {"userNameQuery": {"userName": SERVER_USER, "method": "TEXT_QUERY_METHOD_EQUALS"}}
    found = call(client, "POST", "/management/v1/users/_search", {"queries": [query]})
    if found.get("result"):
        user_id = found["result"][0]["id"]
    else:
        machine = {
            "userName": SERVER_USER,
            "name": "TruckMaps server",
            "accessTokenType": "ACCESS_TOKEN_TYPE_BEARER",
        }
        user_id = call(client, "POST", "/management/v1/users/machine", machine)["userId"]
    member = {"userId": user_id, "roles": ["ORG_USER_MANAGER"]}
    call(client, "POST", "/management/v1/orgs/me/members", member, allow={409})
    if "TRUCKMAPS_ZITADEL_TOKEN=" in (ENV_FILE.read_text("utf-8") if ENV_FILE.exists() else ""):
        return None
    pat = {"expirationDate": "2099-01-01T00:00:00Z"}
    return call(client, "POST", f"/management/v1/users/{user_id}/pats", pat)["token"]


def ensure_smtp(client: httpx.Client) -> None:
    configs = call(client, "POST", "/admin/v1/smtp/_search", {}).get("result", [])
    mailpit = next((c for c in configs if c.get("host") == SMTP["host"]), None)
    if mailpit is None:
        mailpit = {"id": call(client, "POST", "/admin/v1/smtp", SMTP)["id"]}
    if mailpit.get("state") != "SMTP_CONFIG_ACTIVE":
        call(client, "POST", f"/admin/v1/smtp/{mailpit['id']}/_activate", {})


def ensure_branding(client: httpx.Client) -> None:
    """Wygląd ekranów logowania jak TruckMaps: kolory, logo, bez znaku wodnego Zitadela."""
    # 400 = polityka już ma te wartości (Zitadel odrzuca zmianę bez zmian).
    call(client, "PUT", "/admin/v1/policies/label", LABEL_POLICY, allow={400})
    for name, asset in BRANDING_ASSETS.items():
        path = BRANDING_DIR / name.split("#")[0]
        response = client.post(
            f"/assets/v1/instance/policy/label/{asset}",
            files={"file": (path.name, path.read_bytes(), "image/svg+xml")},
        )
        if response.is_error:
            sys.exit(f"Logo {asset} → {response.status_code}: {response.text}")
    # Zmiany wyglądu czekają w podglądzie, dopóki ich nie aktywujemy.
    call(client, "POST", "/admin/v1/policies/label/_activate", {})
    for locale, texts in LOGIN_TEXTS.items():
        body = {"instance": True, "locale": locale, "translations": texts}
        call(client, "PUT", "/v2/settings/hosted_login_translation", body)


def call(
    client: httpx.Client, method: str, path: str, body: dict, *, allow: set[int] = frozenset()
) -> dict:
    response = client.request(method, path, json=body)
    if response.status_code in allow:
        return {}
    if response.is_error:
        sys.exit(f"{method} {path} → {response.status_code}: {response.text}")
    return response.json()


def write_env(values: dict[str, str]) -> None:
    """Uzupełnia .env, zachowując pozostałe wpisy."""
    lines = ENV_FILE.read_text(encoding="utf-8").splitlines() if ENV_FILE.exists() else []
    kept = [line for line in lines if line.split("=", 1)[0].strip() not in values]
    kept += [f"{key}={value}" for key, value in values.items()]
    ENV_FILE.write_text("\n".join(kept) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
