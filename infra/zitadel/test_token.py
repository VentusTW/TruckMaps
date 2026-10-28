"""Wypisuje token dostępu do API TruckMaps dla konta technicznego "truckmaps-e2e".

Do testów API bez przeglądarki (np. curl, skrypty). Tylko lokalnie: konto i jego
sekret powstają w lokalnym Zitadelu, sekret leży w infra/data (poza repozytorium).

    .venv\\Scripts\\python infra\\zitadel\\test_token.py
"""

import json
import sys
from pathlib import Path

import httpx

ISSUER = "http://localhost:8080"
USERNAME = "truckmaps-e2e"

REPO = Path(__file__).resolve().parents[2]
BOOTSTRAP = REPO / "infra" / "data" / "zitadel-bootstrap"
SECRET_FILE = BOOTSTRAP / "e2e-client.json"


def main() -> None:
    credentials = load_or_create_credentials()
    project_id = read_env(REPO / ".env")["TRUCKMAPS_OIDC_PROJECT_ID"]
    response = httpx.post(
        f"{ISSUER}/oauth/v2/token",
        data={
            "grant_type": "client_credentials",
            "scope": f"openid urn:zitadel:iam:org:project:id:{project_id}:aud",
        },
        auth=(credentials["clientId"], credentials["clientSecret"]),
        timeout=30,
    )
    if response.is_error:
        sys.exit(f"Nie udało się pobrać tokenu: {response.status_code} {response.text}")
    print(response.json()["access_token"])


def load_or_create_credentials() -> dict:
    if SECRET_FILE.exists():
        return json.loads(SECRET_FILE.read_text(encoding="utf-8"))
    pat = (BOOTSTRAP / "admin.pat").read_text().strip()
    admin = httpx.Client(base_url=ISSUER, headers={"Authorization": f"Bearer {pat}"}, timeout=30)
    query = {"userNameQuery": {"userName": USERNAME, "method": "TEXT_QUERY_METHOD_EQUALS"}}
    found = admin.post("/management/v1/users/_search", json={"queries": [query]}).json()
    if found.get("result"):
        user_id = found["result"][0]["id"]
    else:
        created = admin.post(
            "/management/v1/users/machine",
            json={
                "userName": USERNAME,
                "name": "TruckMaps – testy API",
                "accessTokenType": "ACCESS_TOKEN_TYPE_JWT",
            },
        )
        created.raise_for_status()
        user_id = created.json()["userId"]
    secret = admin.put(f"/management/v1/users/{user_id}/secret", json={})
    secret.raise_for_status()
    credentials = {k: secret.json()[k] for k in ("clientId", "clientSecret")}
    SECRET_FILE.write_text(json.dumps(credentials), encoding="utf-8")
    return credentials


def read_env(path: Path) -> dict[str, str]:
    lines = path.read_text(encoding="utf-8").splitlines()
    return dict(line.split("=", 1) for line in lines if "=" in line and not line.startswith("#"))


if __name__ == "__main__":
    main()
