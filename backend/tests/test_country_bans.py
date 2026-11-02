from datetime import date

from fastapi.testclient import TestClient

from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.config import Settings
from truckmaps.core.country_bans import country_bans
from truckmaps.sdk import Principal


class FakeVerifier:
    def verify(self, token: str) -> Principal:
        if not token.startswith("user-"):
            raise InvalidToken(token)
        return Principal(subject=token.removeprefix("user-"))


def test_poland_holidays_and_summer_weekends():
    found = country_bans("PL", date(2026, 7, 31), 3)
    titles = [(d.day.isoformat(), d.starts_at.hour, d.ends_at.hour) for d in found.days]
    # Piątek, sobota i niedziela wakacji.
    assert titles == [("2026-07-31", 18, 22), ("2026-08-01", 8, 14), ("2026-08-02", 8, 22)]
    assert found.known and "12 t" in found.vehicles and found.days[0].roads == "wszystkie drogi"


def test_germany_regional_holidays_and_summer_roads():
    found = country_bans("DE", date(2026, 10, 31), 2)
    assert [(r.day.isoformat(), r.name) for r in found.regional] == [
        ("2026-10-31", "Reformationstag"),
        ("2026-11-01", "Allerheiligen"),
    ]
    assert "BY" in found.regional[1].regions
    saturday = country_bans("DE", date(2026, 7, 4), 1).days
    assert saturday[0].roads.startswith("tylko drogi: A1, A2") and not saturday[0].verified


def test_endpoint_language_and_unknown_country(database):
    app = create_app(Settings(), modules=[], token_verifier=FakeVerifier(), database=database)
    client = TestClient(app)
    headers = {"Authorization": "Bearer user-anna", "Accept-Language": "en"}
    body = client.get("/api/timebans/lt", headers=headers).json()
    assert (body["country"], body["name"], body["known"], body["days"]) == (
        "LT",
        "Lithuania",
        False,
        [],
    )
    assert client.get("/api/timebans/XX", headers=headers).status_code == 404
