"""Konfiguruje lokalnego Zitadela dla TruckMaps. Można uruchamiać wielokrotnie.

- projekt "TruckMaps" i aplikacja OIDC "truckmaps-dev" (PKCE, bez sekretu, tokeny JWT),
- wysyłka maili przez Mailpit (http://localhost:8025),
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

    write_env(
        {
            "TRUCKMAPS_OIDC_ISSUER": ISSUER,
            "TRUCKMAPS_OIDC_CLIENT_ID": client_id,
            "TRUCKMAPS_OIDC_PROJECT_ID": project_id,
            "TRUCKMAPS_PUBLIC_URL": PUBLIC_URL,
        }
    )
    print(f"Projekt {PROJECT_NAME}: {project_id}")
    print(f"Aplikacja {APP_NAME}: client_id={client_id}")
    print(f"Zapisano {ENV_FILE}")


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


def ensure_smtp(client: httpx.Client) -> None:
    configs = call(client, "POST", "/admin/v1/smtp/_search", {}).get("result", [])
    mailpit = next((c for c in configs if c.get("host") == SMTP["host"]), None)
    if mailpit is None:
        mailpit = {"id": call(client, "POST", "/admin/v1/smtp", SMTP)["id"]}
    if mailpit.get("state") != "SMTP_CONFIG_ACTIVE":
        call(client, "POST", f"/admin/v1/smtp/{mailpit['id']}/_activate", {})


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
