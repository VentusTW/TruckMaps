from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from truckmaps.core import inbox, mailer
from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.config import Settings
from truckmaps.sdk import Principal


class Verifier:
    """Konto „ola” ma adres e-mail w koncie logowania, „bez” – nie."""

    def verify(self, token: str) -> Principal:
        if not token.startswith("user-"):
            raise InvalidToken(token)
        subject = token.removeprefix("user-")
        claims = {"email": f"{subject}@example.com"} if subject != "bez" else {}
        return Principal(subject=subject, claims=claims)


class FakeSmtp:
    sent: list = []

    def __init__(self, host, port, timeout):
        self.host = host

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def starttls(self):
        pass

    def login(self, user, password):
        pass

    def send_message(self, message):
        FakeSmtp.sent.append(message)


@pytest.fixture
def client(database, monkeypatch):
    FakeSmtp.sent = []
    monkeypatch.setattr(mailer.smtplib, "SMTP", FakeSmtp)
    app = create_app(
        Settings(smtp_host="smtp.example.com"),
        modules=[],
        token_verifier=Verifier(),
        database=database,
    )
    with TestClient(app) as client:
        yield client


def headers(who):
    return {"Authorization": f"Bearer user-{who}"}


def test_email_only_for_users_who_turned_it_on(client, database):
    settings = client.get("/api/me/settings", headers=headers("ola")).json()
    assert (settings["email_notifications"], settings["email_available"]) == (False, True)
    assert settings["email"] == "ola@example.com"
    on = client.put("/api/me/settings", json={"email_notifications": True}, headers=headers("ola"))
    assert on.json()["email_notifications"] is True
    no_address = client.put(
        "/api/me/settings", json={"email_notifications": True}, headers=headers("bez")
    )
    assert no_address.status_code == 422
    client.put("/api/me/settings", json={"language": "en"}, headers=headers("ola"))

    smtp = mailer.SmtpSettings(host="smtp.example.com")
    with database.session() as db:
        data = {"vehicle_name": "Zestaw", "field": "insurance_until"}
        inbox.send(db, ["ola", "jan"], inbox.Kind.VEHICLE_DUE, sender_name="", data=data)
        inbox.send(db, ["ola"], "module.unknown", sender_name="")
        db.commit()
        assert mailer.send_pending(db, smtp) == 2  # „jan” nie włączył powiadomień
        assert mailer.send_pending(db, smtp) == 0  # każda wiadomość raz
        # Wiadomość sprzed godziny nie idzie (np. po przerwie serwera).
        inbox.send(db, ["ola"], inbox.Kind.ACCESS_CLOSED, sender_name="")
        db.commit()
        later = datetime.now(UTC) + timedelta(hours=2)
        assert mailer.send_pending(db, smtp, now=later) == 0

    first, second = FakeSmtp.sent
    assert (first["To"], first["Subject"]) == (
        "ola@example.com",
        "TruckMaps: Vehicle deadline: Zestaw",
    )
    assert "Account → E-mail notifications" in first.get_content()
    assert second["Subject"] == "TruckMaps: New message in your inbox"
