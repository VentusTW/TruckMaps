import base64
from datetime import UTC, datetime

import pytest
from fastapi.testclient import TestClient

from truckmaps.core import fuel_cards
from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.config import Settings
from truckmaps.sdk import Principal

TRACTOR = {
    "name": "MAN TGX",
    "kind": "tractor",
    "height_m": 4.0,
    "width_m": 2.55,
    "length_m": 6.0,
    "gvw_t": 18,
    "axle_load_t": 11.5,
    "axle_count": 2,
}

# Układ jak w polskich wyciągach (Orlen Flota / E100): średnik, przecinek dziesiętny, cp1250.
ORLEN = """Wyciąg za okres 01.10.2026 - 31.10.2026
Data transakcji;Godzina;Nr karty;Nr rejestracyjny;Stacja;Produkt;Ilość;Cena jednostkowa;Kwota netto;Kwota brutto;Waluta;Przebieg
02.10.2026;06:15;7071 0000 1111;WX 12345;Orlen Łódź;Olej napędowy;412,50;6,12;2 052,49;2 524,56;PLN;512340
05.10.2026;18:40;7071 0000 1111;;Orlen Poznań;AdBlue;30,00;3,10;75,61;93,00;PLN;513100
06.10.2026;07:00;7071 0000 2222;KR 99999;Orlen Kraków;ON Verva;100,00;6,50;528,46;650,00;PLN;
07.10.2026;08:00;7071 0000 1111;WX 12345;Orlen Łódź;Myjnia;1;80,00;65,04;80,00;PLN;
zły wiersz;;;;;;;;;;;
"""  # noqa: E501

# Układ DKV/UTA po angielsku: przecinek, kropka dziesiętna, data ISO w jednej kolumnie.
DKV = """Transaction date/time,Card number,License plate,Country,Product name,Quantity,Gross amount,Currency
2026-10-10 09:30,700000123,WX12345,DE,Diesel,500.25,"1,050.40",EUR
2026-10-11T14:05:00,700000123,WX12345,AT,AdBlue,20.0,25.00,EUR
"""  # noqa: E501


class FakeVerifier:
    def verify(self, token: str) -> Principal:
        kind, _, subject = token.partition("-")
        if kind != "user" or not subject:
            raise InvalidToken(token)
        return Principal(subject=subject, claims={})


def as_user(subject: str) -> dict:
    return {"Authorization": f"Bearer user-{subject}"}


@pytest.fixture
def client(database):
    app = create_app(
        Settings(dev_grant_all=True), modules=[], token_verifier=FakeVerifier(), database=database
    )
    return TestClient(app)


def test_parse_polish_statement():
    parsed = fuel_cards.parse(ORLEN.encode("cp1250"))
    assert parsed.skipped == 1
    assert parsed.columns["liters"] == "Ilość" and parsed.columns["amount"] == "Kwota brutto"
    first, adblue, verva, wash = parsed.rows
    assert first.at == datetime(2026, 10, 2, 6, 15, tzinfo=UTC)
    assert (first.liters, first.amount, first.net) == (412.5, 2524.56, 2052.49)
    assert (first.card, first.plate, first.odometer) == ("707100001111", "WX 12345", 512340)
    assert first.station == "Orlen Łódź" and first.currency == "PLN"
    assert [r.product_type for r in parsed.rows] == ["diesel", "adblue", "diesel", "other"]
    assert verva.odometer is None and adblue.plate == "" and wash.liters == 1


def test_parse_english_statement_and_errors():
    parsed = fuel_cards.parse(DKV.encode())
    assert [(r.at.hour, r.liters, r.amount, r.currency) for r in parsed.rows] == [
        (9, 500.25, 1050.4, "EUR"),
        (14, 20.0, 25.0, "EUR"),
    ]
    assert parsed.rows[0].country == "DE"
    with pytest.raises(fuel_cards.FuelCsvError) as error:
        fuel_cards.parse(b"a;b;c\n1;2;3\n")
    assert error.value.code == "fuel.no_columns"
    with pytest.raises(fuel_cards.FuelCsvError) as error:
        fuel_cards.parse("Data;Ilość;Kwota\nbrak;x;y\n".encode())
    assert error.value.code == "fuel.no_rows"


@pytest.mark.parametrize(
    ("text", "value"),
    [
        ("1 234,56", 1234.56),
        ("1.234,56", 1234.56),
        ("1,234.56", 1234.56),
        ("12,5 l", 12.5),
        ("", None),
    ],
)
def test_numbers(text, value):
    assert fuel_cards._number(text) == value


def test_import_matches_vehicles_cards_and_skips_duplicates(client):
    company = client.post("/api/companies", json={"name": "Trans"}, headers=as_user("owner")).json()
    cid = company["id"]
    truck = client.post(
        "/api/vehicles",
        json=TRACTOR | {"company_id": cid, "plate": "WX 12345"},
        headers=as_user("owner"),
    ).json()
    body = {"name": "orlen_2026-10.csv", "data": base64.b64encode(ORLEN.encode("cp1250")).decode()}
    url = f"/api/companies/{cid}/fuel-cards/import"
    result = client.post(url, json=body, headers=as_user("owner"))
    assert result.status_code == 200, result.text
    out = result.json()
    assert (out["imported"], out["duplicates"], out["skipped"]) == (4, 0, 1)
    assert out["unmatched"] == ["KR 99999"]
    assert out["liters"] == 542.5  # bez myjni
    assert out["amount"] == {"PLN": 3347.56}
    again = client.post(url, json=body, headers=as_user("owner")).json()
    assert (again["imported"], again["duplicates"]) == (0, 4)

    # AdBlue bez numeru rejestracyjnego – pojazd po karcie.
    records = client.get(
        f"/api/companies/{cid}/records",
        params={"entity_type": "vehicle", "entity_id": truck["id"], "kind": "fuel"},
        headers=as_user("owner"),
    ).json()
    assert sorted(r["data"]["product_type"] for r in records) == ["adblue", "diesel", "other"]

    dkv = {
        "name": "dkv.csv",
        "data": base64.b64encode(DKV.encode()).decode(),
        "vehicle_id": truck["id"],
    }
    assert client.post(url, json=dkv, headers=as_user("owner")).json()["amount"] == {"EUR": 1075.4}

    summary = client.get(
        f"/api/companies/{cid}/fuel-cards/summary", params={"months": 36}, headers=as_user("owner")
    ).json()
    assert summary["count"] == 6
    assert summary["amount"] == {"PLN": 3347.56, "EUR": 1075.4}
    top = summary["vehicles"][0]
    assert (top["vehicle_id"], top["plate"], top["count"]) == (truck["id"], "WX 12345", 5)
    assert (top["liters"], top["adblue_liters"]) == (912.75, 50.0)
    assert top["last"].startswith("2026-10-11")
    assert summary["vehicles"][1]["vehicle_id"] is None


def test_import_permissions_and_bad_files(client):
    cid = client.post("/api/companies", json={"name": "Trans"}, headers=as_user("owner")).json()[
        "id"
    ]
    url = f"/api/companies/{cid}/fuel-cards/import"
    body = {"name": "x.csv", "data": base64.b64encode(DKV.encode()).decode()}
    assert client.post(url, json=body, headers=as_user("obcy")).status_code == 404
    assert (
        client.post(url, json=body | {"data": "@@@"}, headers=as_user("owner")).status_code == 422
    )
    wrong = client.post(
        url, json=body | {"data": base64.b64encode(b"x;y\n1;2").decode()}, headers=as_user("owner")
    )
    assert wrong.status_code == 422 and "kolumn" in wrong.json()["detail"]
    missing = client.post(url, json=body | {"vehicle_id": "nie-ma"}, headers=as_user("owner"))
    assert missing.status_code == 404
    summary = f"/api/companies/{cid}/fuel-cards/summary"
    assert client.get(summary, headers=as_user("obcy")).status_code == 404
