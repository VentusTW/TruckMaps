from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select, update

from truckmaps.core import admin
from truckmaps.core.admin import AccessGrant, AdminAccount, AuditEntry
from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.config import Settings
from truckmaps.sdk import Principal

COMPANY = {"name": "Trans-Miś", "tax_id": "PL123", "cost_currency": "PLN"}


class FakeVerifier:
    """``user-X`` – logowanie hasłem, ``mfa-X`` – z drugim składnikiem."""

    def verify(self, token: str) -> Principal:
        kind, _, subject = token.partition("-")
        if kind not in {"user", "mfa"} or not subject:
            raise InvalidToken(token)
        amr = ["pwd", "mfa", "otp"] if kind == "mfa" else ["pwd"]
        return Principal(subject=subject, claims={"amr": amr})


def as_user(subject: str, mfa: bool = False) -> dict:
    return {
        "Authorization": f"Bearer {'mfa' if mfa else 'user'}-{subject}",
        "User-Agent": "TruckMaps-Admin/1.0",
    }


@pytest.fixture
def client(database):
    app = create_app(Settings(), modules=[], token_verifier=FakeVerifier(), database=database)
    return TestClient(app)


@pytest.fixture
def admins(database):
    with database.session() as db:
        db.add(AdminAccount(subject="boss", name="Anna", role="full", created_by="cli:test"))
        db.add(AdminAccount(subject="help", name="Piotr", role="support", created_by="cli:test"))
        db.commit()


@pytest.fixture
def company(client) -> str:
    response = client.post("/api/companies", json=COMPANY, headers=as_user("owner"))
    return response.json()["id"]


def audit(database) -> list[AuditEntry]:
    with database.session() as db:
        return db.scalars(select(AuditEntry).order_by(AuditEntry.id)).all()


def test_admin_api_only_for_admin_accounts_and_every_call_is_logged(client, database, admins):
    assert client.get("/api/admin/companies").status_code == 401
    assert client.get("/api/admin/companies", headers=as_user("owner", mfa=True)).status_code == 403
    response = client.get("/api/admin/me", headers=as_user("boss", mfa=True))
    assert response.json() == {"subject": "boss", "name": "Anna", "role": "full"}

    entries = audit(database)
    assert [(e.subject, e.status_code) for e in entries] == [
        ("", 401),
        ("owner", 403),
        ("boss", 200),
    ]
    assert entries[2].role == "full"
    assert entries[2].path == "/api/admin/me"
    assert entries[2].user_agent == "TruckMaps-Admin/1.0"
    assert entries[2].ip


def test_admin_requires_second_factor(client, database, admins):
    response = client.get("/api/admin/me", headers=as_user("boss"))
    assert response.status_code == 403
    assert "drugim składnikiem" in response.json()["detail"]
    assert audit(database)[-1].subject == "boss"


def test_disabled_admin_has_no_access(client, database, admins):
    admin.main(["disable", "help"], database=database)
    assert client.get("/api/admin/me", headers=as_user("help", mfa=True)).status_code == 403


def test_lists_with_search_and_filters(client, database, admins, company):
    client.post(
        "/api/companies",
        json={"name": "Inna firma", "cost_currency": "EUR"},
        headers=as_user("other"),
    )
    client.post(
        f"/api/companies/{company}/bases",
        json={"name": "Baza Tarnów", "lat": 50.0, "lon": 21.0},
        headers=as_user("owner"),
    )
    code = client.post(
        f"/api/companies/{company}/invites", json={"role": "driver"}, headers=as_user("owner")
    ).json()["code"]
    headers = as_user("help", mfa=True)

    found = client.get("/api/admin/companies", params={"q": "miś"}, headers=headers).json()
    assert found["total"] == 1
    assert found["items"][0]["members"] == 1
    assert found["items"][0]["access_granted"] is False
    assert client.get("/api/admin/companies", headers=headers).json()["total"] == 2

    members = client.get(
        "/api/admin/members", params={"company_id": company, "role": "owner"}, headers=headers
    ).json()
    assert [m["subject"] for m in members["items"]] == ["owner"]
    assert (
        client.get("/api/admin/bases", params={"q": "tarn"}, headers=headers).json()["total"] == 1
    )
    invites = client.get("/api/admin/invites", params={"active": True}, headers=headers).json()
    assert invites["total"] == 1
    assert code not in str(invites)
    accounts = client.get("/api/admin/accounts", params={"q": "own"}, headers=headers).json()
    assert accounts["items"][0]["companies"] == 1
    for path in ("vehicles", "reports", "releases", "licenses", "audit"):
        assert client.get(f"/api/admin/{path}", headers=headers).status_code == 200


def test_paging(client, admins):
    for i in range(3):
        client.post(
            "/api/companies",
            json={"name": f"Firma {i}", "cost_currency": "EUR"},
            headers=as_user(f"o{i}"),
        )
    page = client.get(
        "/api/admin/companies", params={"limit": 2, "offset": 2}, headers=as_user("boss", mfa=True)
    ).json()
    assert page["total"] == 3
    assert [c["name"] for c in page["items"]] == ["Firma 2"]


def test_change_needs_owner_grant_and_lands_in_company_log(client, database, admins, company):
    change = {**COMPANY, "name": "Trans-Miś Sp. z o.o."}
    boss = as_user("boss", mfa=True)
    assert (
        client.put(f"/api/admin/companies/{company}", json=change, headers=boss).status_code == 403
    )

    # Tylko właściciel udziela dostępu.
    grant = {"scopes": ["company"], "minutes": 90, "note": "zgłoszenie 12"}
    url = f"/api/companies/{company}/admin-access"
    dispatcher_code = client.post(
        f"/api/companies/{company}/invites", json={"role": "dispatcher"}, headers=as_user("owner")
    ).json()["code"]
    client.post(f"/api/invites/{dispatcher_code}/accept", json={}, headers=as_user("disp"))
    assert client.post(url, json=grant, headers=as_user("disp")).status_code == 403
    created = client.post(url, json=grant, headers=as_user("owner")).json()
    assert created["active"] is True

    # Wsparcie ma tylko odczyt, także przy zgodzie; zgoda na firmę nie obejmuje baz.
    help_ = as_user("help", mfa=True)
    assert (
        client.put(f"/api/admin/companies/{company}", json=change, headers=help_).status_code == 403
    )
    response = client.put(f"/api/admin/companies/{company}", json=change, headers=boss)
    assert response.status_code == 200
    assert response.json()["name"] == "Trans-Miś Sp. z o.o."

    log = client.get(url, headers=as_user("owner")).json()
    assert log["changes"] == [
        {
            "at": log["changes"][0]["at"],
            "admin": "Anna",
            "action": "company.update",
            "changes": {"name": ["Trans-Miś", "Trans-Miś Sp. z o.o."]},
        }
    ]
    assert log["grants"][0]["note"] == "zgłoszenie 12"

    # Cofnięcie – kolejne zmiany odrzucone, a odrzucona próba nie jest zmianą dla firmy.
    assert client.delete(f"{url}/{created['id']}", headers=as_user("owner")).status_code == 204
    assert (
        client.put(f"/api/admin/companies/{company}", json=COMPANY, headers=boss).status_code == 403
    )
    assert len(client.get(url, headers=as_user("owner")).json()["changes"]) == 1
    assert client.get(url, headers=as_user("disp")).status_code == 403


def test_expired_grant_does_not_allow_changes(client, database, admins, company):
    url = f"/api/companies/{company}/admin-access"
    client.post(url, json={"scopes": ["company", "bases"], "minutes": 60}, headers=as_user("owner"))
    with database.session() as db:
        db.execute(update(AccessGrant).values(expires_at=datetime.now(UTC) - timedelta(minutes=1)))
        db.commit()
    response = client.put(
        f"/api/admin/companies/{company}", json=COMPANY, headers=as_user("boss", mfa=True)
    )
    assert response.status_code == 403
    assert client.get(url, headers=as_user("owner")).json()["grants"][0]["active"] is False


def test_grant_limits(client, company):
    url = f"/api/companies/{company}/admin-access"
    owner = as_user("owner")
    assert (
        client.post(url, json={"scopes": ["company"], "minutes": 481}, headers=owner).status_code
        == 422
    )
    assert client.post(url, json={"scopes": [], "minutes": 60}, headers=owner).status_code == 422
    assert (
        client.post(url, json={"scopes": ["all"], "minutes": 60}, headers=owner).status_code == 422
    )


def test_base_change_with_grant(client, admins, company):
    base = client.post(
        f"/api/companies/{company}/bases",
        json={"name": "Baza", "lat": 50.0, "lon": 21.0},
        headers=as_user("owner"),
    ).json()
    url = f"/api/companies/{company}/admin-access"
    client.post(url, json={"scopes": ["bases"], "minutes": 60}, headers=as_user("owner"))
    response = client.put(
        f"/api/admin/companies/{company}/bases/{base['id']}",
        json={"name": "Baza", "label": "Tarnów, Krakowska 1", "lat": 50.0, "lon": 21.0},
        headers=as_user("boss", mfa=True),
    )
    assert response.status_code == 200
    change = client.get(url, headers=as_user("owner")).json()["changes"][0]
    assert change["changes"] == {"base": ["Baza", "Baza"], "label": ["", "Tarnów, Krakowska 1"]}


def test_cli_manages_admins_and_logs_it(database, capsys):
    admin.main(["add", "sub-1", "--role", "full", "--name", "Anna"], database=database)
    admin.main(["add", "sub-1", "--role", "support"], database=database)
    admin.main(["list"], database=database)
    assert "support" in capsys.readouterr().out
    with database.session() as db:
        account = db.get(AdminAccount, "sub-1")
        assert (account.role, account.name) == ("support", "Anna")
    entries = audit(database)
    assert [e.action for e in entries] == ["admin.add", "admin.add"]
    assert entries[1].changes == {"role": ["full", "support"]}
    assert entries[0].subject.startswith("cli:")
    with pytest.raises(SystemExit):
        admin.main(["disable", "nobody"], database=database)


def test_mfa_required_by_default():
    assert Settings.from_env({}).admin_require_mfa is True
    assert Settings.from_env({"TRUCKMAPS_ADMIN_REQUIRE_MFA": "0"}).admin_require_mfa is False


def test_admin_requests_access_owner_accepts_in_inbox_and_extends(
    client, database, admins, company
):
    boss = as_user("boss", mfa=True)
    request = {"scopes": ["company"], "note": "Poprawa NIP – zgłoszenie 7"}
    assert (
        client.post(
            f"/api/admin/companies/{company}/access-requests",
            json=request,
            headers=as_user("help", mfa=True),
        ).status_code
        == 403
    )
    created = client.post(
        f"/api/admin/companies/{company}/access-requests", json=request, headers=boss
    ).json()
    assert created["state"] == "pending"
    change = {**COMPANY, "tax_id": "PL999"}
    assert (
        client.put(f"/api/admin/companies/{company}", json=change, headers=boss).status_code == 403
    )

    # Prośba w skrzynce właściciela – wyróżniona, z imieniem administratora i powodem.
    inbox = client.get("/api/me/messages", headers=as_user("owner")).json()
    assert inbox["unread"] == 1
    message = inbox["items"][0]
    assert (message["kind"], message["sender_name"]) == ("admin_access_request", "Anna")
    assert message["data"] == {"scopes": ["company"], "note": "Poprawa NIP – zgłoszenie 7"}
    assert message["grant"]["state"] == "pending"
    assert client.get("/api/me/messages", headers=as_user("other")).json()["unread"] == 0

    url = f"/api/companies/{company}/admin-access/{created['id']}"
    accepted = client.post(f"{url}/accept", json={}, headers=as_user("owner")).json()
    assert accepted["state"] == "active"
    minutes = (
        datetime.fromisoformat(accepted["expires_at"])
        - datetime.fromisoformat(accepted["granted_at"])
    ).total_seconds() / 60
    assert minutes == 60
    assert client.post(f"{url}/accept", json={}, headers=as_user("owner")).status_code == 409
    assert client.get("/api/me/messages", headers=as_user("owner")).json()["unread"] == 0
    assert (
        client.put(f"/api/admin/companies/{company}", json=change, headers=boss).status_code == 200
    )

    # Administrator widzi termin i prosi o przedłużenie; właściciel przedłuża.
    mine = client.get("/api/admin/grants", headers=boss).json()
    assert (mine[0]["state"], mine[0]["company_name"]) == ("active", "Trans-Miś")
    path = f"/api/admin/grants/{created['id']}"
    assert (
        client.post(f"{path}/extension-request", json={"minutes": 30}, headers=boss).status_code
        == 204
    )
    inbox = client.get("/api/me/messages", headers=as_user("owner")).json()
    assert (inbox["items"][0]["kind"], inbox["items"][0]["data"]) == (
        "admin_extension_request",
        {"minutes": 30},
    )
    extended = client.post(f"{url}/extend", json={"minutes": 30}, headers=as_user("owner")).json()
    assert extended["expires_at"] > accepted["expires_at"]

    # Administrator kończy wcześniej – właściciel dostaje wiadomość, zmiany zablokowane.
    assert client.post(f"{path}/close", headers=boss).status_code == 204
    assert client.get("/api/admin/grants", headers=boss).json()[0]["state"] == "closed"
    inbox = client.get("/api/me/messages", headers=as_user("owner")).json()
    assert inbox["items"][0]["kind"] == "admin_access_closed"
    assert (
        client.put(f"/api/admin/companies/{company}", json=change, headers=boss).status_code == 403
    )
    assert client.post(f"{url}/extend", json={}, headers=as_user("owner")).status_code == 409


def test_owner_rejects_request_and_reads_message(client, admins, company):
    boss = as_user("boss", mfa=True)
    created = client.post(
        f"/api/admin/companies/{company}/access-requests",
        json={"scopes": ["bases"], "note": "Adres bazy"},
        headers=boss,
    ).json()
    url = f"/api/companies/{company}/admin-access/{created['id']}"
    assert client.post(f"{url}/reject", headers=as_user("disp")).status_code == 404
    assert client.post(f"{url}/reject", headers=as_user("owner")).json()["state"] == "rejected"
    assert client.get("/api/admin/grants", headers=boss).json()[0]["state"] == "rejected"
    assert (
        client.post(
            f"/api/admin/grants/{created['id']}/extension-request", json={}, headers=boss
        ).status_code
        == 409
    )

    message = client.get("/api/me/messages", headers=as_user("owner")).json()["items"][0]
    assert message["grant"]["state"] == "rejected"
    assert (
        client.post(f"/api/me/messages/{message['id']}/read", headers=as_user("other")).status_code
        == 404
    )
    assert (
        client.post(f"/api/me/messages/{message['id']}/read", headers=as_user("owner")).status_code
        == 204
    )


def test_extension_is_capped(client, admins, company):
    url = f"/api/companies/{company}/admin-access"
    created = client.post(
        url, json={"scopes": ["company"], "minutes": 480}, headers=as_user("owner")
    ).json()
    extended = client.post(
        f"{url}/{created['id']}/extend", json={"minutes": 480}, headers=as_user("owner")
    ).json()
    hours = (
        datetime.fromisoformat(extended["expires_at"]) - datetime.now(UTC)
    ).total_seconds() / 3600
    assert 7.9 < hours <= 8
