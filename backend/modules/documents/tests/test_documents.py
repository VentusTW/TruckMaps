import json
import re
import zlib
from datetime import UTC, datetime, timedelta
from importlib import resources

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.pool import StaticPool
from truckmaps_documents import pdf
from truckmaps_documents.catalog import KINDS
from truckmaps_documents.module import Base as DocumentsBase
from truckmaps_documents.module import DocumentsModule
from truckmaps_documents.prefill import Template, fields_for
from truckmaps_documents.render import Doc, to_html, to_pdf

from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.config import Settings
from truckmaps.core.db import Base, Database
from truckmaps.sdk import Principal, i18n

TRACTOR = {
    "name": "MAN TGX",
    "plate": "WGM 1234A",
    "kind": "tractor",
    "height_m": 4.0,
    "width_m": 2.55,
    "length_m": 6.0,
    "gvw_t": 18,
    "axle_load_t": 11.5,
    "axle_count": 2,
    "odometer_km": 250_000,
}
SEMITRAILER = TRACTOR | {
    "name": "Krone",
    "plate": "WGM 9876B",
    "kind": "semitrailer",
    "length_m": 13.6,
    "gvw_t": 24,
    "odometer_km": None,
}
PROFILE = {
    "legal_name": "Trans-Miś Sp. z o.o.",
    "address": "ul. Łódzka 5",
    "postal_code": "00-950",
    "city": "Warszawa",
    "country": "PL",
    "vat_id": "PL5250000000",
    "licence_number": "LW/0001/2026",
    "ocp_policy": "OCP-77",
    "ocp_insurer": "Ubezpieczyciel SA",
    "ocp_sum": "200 000 EUR",
    "contact_person": "Ola Nowak",
}


class FakeVerifier:
    def verify(self, token: str) -> Principal:
        if not token.startswith("user-"):
            raise InvalidToken(token)
        subject = token.removeprefix("user-")
        return Principal(subject=subject, claims={"name": subject.title()})


def as_user(subject: str) -> dict:
    return {"Authorization": f"Bearer user-{subject}"}


@pytest.fixture
def client():
    database = Database(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(database.engine)
    DocumentsBase.metadata.create_all(database.engine)
    app = create_app(
        Settings(dev_grant_all=True),
        modules=[DocumentsModule()],
        token_verifier=FakeVerifier(),
        database=database,
    )
    with TestClient(app) as client:
        yield client


def join(client, company_id: str, subject: str, role: str) -> None:
    invite = client.post(
        f"/api/companies/{company_id}/invites", json={"role": role}, headers=as_user("olek")
    ).json()
    accepted = client.post(
        f"/api/invites/{invite['code']}/accept", json={}, headers=as_user(subject)
    )
    assert accepted.status_code == 200


@pytest.fixture
def company(client):
    company_id = client.post(
        "/api/companies",
        json={"name": "Trans-Miś", "tax_id": "5250000000"},
        headers=as_user("olek"),
    ).json()["id"]
    join(client, company_id, "jan", "driver")
    owner = as_user("olek")
    tractor = client.post("/api/vehicles", json=TRACTOR | {"company_id": company_id}, headers=owner)
    trailer = client.post(
        "/api/vehicles", json=SEMITRAILER | {"company_id": company_id}, headers=owner
    )
    assert tractor.status_code == 201, tractor.text
    tractor_id, trailer_id = tractor.json()["id"], trailer.json()["id"]
    coupled = client.put(
        f"/api/vehicles/{tractor_id}/trailer", json={"trailer_id": trailer_id}, headers=owner
    )
    assert coupled.status_code == 200, coupled.text
    members = client.get(f"/api/companies/{company_id}", headers=owner).json()["members"]
    jan = next(m["id"] for m in members if m["display_name"] == "Jan")
    assigned = client.put(
        f"/api/vehicles/{tractor_id}/driver", json={"member_id": jan}, headers=owner
    )
    assert assigned.status_code == 200, assigned.text
    return {"id": company_id, "tractor": tractor_id, "trailer": trailer_id}


API = "/api/m/documents"


def locale(name: str) -> dict:
    return json.loads(
        (resources.files("truckmaps_documents") / "locales" / name).read_text("utf-8")
    )


@pytest.fixture
def texts():
    for name in ("pl", "en"):
        i18n.register(name, locale(f"{name}.json"))


def test_kinds_have_translated_labels_in_all_languages():
    keys = set()
    for kind in KINDS.values():
        keys |= {f"documents.kind.{kind.id}", f"documents.basis.{kind.id}"}
        keys |= {f"documents.sign.{s}" for s in kind.signatures}
        for f in kind.fields:
            keys.add(f"documents.field.{f.key}")
            keys |= {f"documents.col.{c}" for c in f.columns}
    for name in ("pl.json", "en.json"):
        entries = json.loads(
            (resources.files("truckmaps_documents") / "locales" / name).read_text("utf-8")
        )
        assert keys <= set(entries), (name, keys - set(entries))
    pl = json.loads(
        (resources.files("truckmaps_documents") / "locales" / "pl.json").read_text("utf-8")
    )
    en = json.loads(
        (resources.files("truckmaps_documents") / "locales" / "en.json").read_text("utf-8")
    )
    assert set(pl) == set(en)


def test_profile_and_template_only_managers_change(client, company):
    cid = company["id"]
    assert client.put(f"{API}/profile", params={"company_id": cid}, json=PROFILE,
                      headers=as_user("jan")).status_code == 403  # fmt: skip
    assert client.put(f"{API}/profile", params={"company_id": cid}, json=PROFILE,
                      headers=as_user("olek")).status_code == 200  # fmt: skip
    got = client.get(f"{API}/profile", params={"company_id": cid}, headers=as_user("jan")).json()
    assert got["city"] == "Warszawa"
    assert (
        client.get(
            f"{API}/profile", params={"company_id": cid}, headers=as_user("obcy")
        ).status_code
        == 404
    )
    template = {
        "defaults": {"payment_days": "30", "goods": "x", "unknown": "y"},
        "hidden": ["temperature", "nope"],
        "terms": "Wymiana palet: nie.",
    }
    saved = client.put(
        f"{API}/templates/transport_order", params={"company_id": cid}, json=template,
        headers=as_user("olek"),
    ).json()  # fmt: skip
    assert saved["defaults"] == {"payment_days": "30"}
    assert saved["hidden"] == ["temperature"]
    assert client.get(f"{API}/templates/bad", params={"company_id": cid},
                      headers=as_user("olek")).status_code == 404  # fmt: skip


def test_prefill_cmr_from_company_vehicle_route_and_cargo(client, company):
    cid = company["id"]
    client.put(f"{API}/profile", params={"company_id": cid}, json=PROFILE, headers=as_user("olek"))
    body = {
        "kind": "cmr",
        "company_id": cid,
        "vehicle_id": company["tractor"],
        "route": {
            "stops": [
                {
                    "label": "Poznań, ul. Magazynowa 1",
                    "country": "PL",
                    "at": "2026-11-06T08:00:00Z",
                },
                {"label": "Berlin", "country": "DE"},
            ],
            "cost_amount": 950,
            "cost_currency": "EUR",
        },
        "cargo": {"items": [{"kind": "euro", "count": 10, "weight_kg": 400, "label": "Płytki"}]},
    }
    result = client.post(f"{API}/prefill", json=body, headers=as_user("jan"))
    assert result.status_code == 200, result.text
    data, sources = result.json()["data"], result.json()["sources"]
    assert data["carrier"].startswith("Trans-Miś Sp. z o.o.\nul. Łódzka 5\n00-950 Warszawa, PL")
    assert "PL5250000000" in data["carrier"] and "LW/0001/2026" in data["carrier"]
    assert data["loading_place_date"] == "Poznań, ul. Magazynowa 1 (PL)\n2026-11-06"
    assert data["delivery_place"] == "Berlin (DE)"
    assert data["goods"] == [
        {"marks": "Płytki", "packages": 10, "packing": "palety EUR", "nature": "Płytki",
         "gross_kg": 4000}
    ]  # fmt: skip
    assert data["tractor_plate"] == "WGM 1234A" and data["trailer_plate"] == "WGM 9876B"
    assert data["charges"] == "950.00 EUR"
    assert data["issued_place"] == "Warszawa"
    assert sources["carrier"] == "company" and sources["goods"] == "cargo"
    assert result.json()["warnings"] == []
    # Obca firma i obcy pojazd
    assert client.post(f"{API}/prefill", json=body, headers=as_user("obcy")).status_code == 404
    other = client.post("/api/companies", json={"name": "Inna"}, headers=as_user("ewa")).json()
    stranger = body | {"company_id": other["id"]}
    assert client.post(f"{API}/prefill", json=stranger, headers=as_user("ewa")).status_code == 404


def test_prefill_order_uses_driver_template_and_warns_without_profile(client, company):
    cid = company["id"]
    client.put(
        f"{API}/templates/transport_order", params={"company_id": cid},
        json={"defaults": {"payment_days": "45"}, "terms": "Kara za przestój: 50 EUR/h."},
        headers=as_user("olek"),
    )  # fmt: skip
    body = {
        "kind": "transport_order",
        "company_id": cid,
        "vehicle_id": company["tractor"],
        "route": {
            "stops": [{"label": "A"}, {"label": "B"}, {"label": "C", "reference": "REF-1"}],
            "distance_km": 612.4,
            "duration_min": 500,
        },
        "cargo": {"items": [{"count": 33, "weight_kg": 500}], "ldm": 13.6},
    }
    result = client.post(f"{API}/prefill", json=body, headers=as_user("olek")).json()
    data = result["data"]
    assert data["driver_name"] == "Jan"
    assert data["carrier"].startswith("Trans-Miś")
    assert [s["stop_type"] for s in data["stops"]] == ["Załadunek", "Przez", "Rozładunek"]
    assert data["stops"][2]["reference"] == "REF-1"
    assert data["distance_km"] == 612 and data["duration_h"] == 8.3
    assert data["goods"][0]["gross_kg"] == 16500 and data["goods"][0]["ldm"] == 13.6
    assert data["vehicle_type"] == "naczepa"
    assert data["payment_days"] == "45" and result["sources"]["payment_days"] == "template"
    assert data["terms"] == "Kara za przestój: 50 EUR/h."
    assert len(result["warnings"]) == 1  # brak profilu firmy
    english = client.post(
        f"{API}/prefill", json=body, headers=as_user("olek") | {"Accept-Language": "en"}
    ).json()
    assert english["data"]["stops"][0]["stop_type"] == "Loading"


def test_prefill_road_card_from_trips(client, company):
    tractor = company["tractor"]
    day = datetime.now(UTC).replace(hour=8, minute=0, second=0, microsecond=0)
    for start, km, loaded in ((day - timedelta(days=3), 50, True), (day, 120.4, True),
                              (day + timedelta(hours=4), 80, False)):  # fmt: skip
        trip = {
            "started_at": start.isoformat(),
            "ended_at": (start + timedelta(hours=2)).isoformat(),
            "distance_km": km,
            "loaded": loaded,
        }
        saved = client.post(f"/api/vehicles/{tractor}/trips", json=trip, headers=as_user("jan"))
        assert saved.status_code == 201, saved.text
    body = {"kind": "road_card", "company_id": company["id"], "vehicle_id": tractor,
            "date_from": day.date().isoformat()}  # fmt: skip
    data = client.post(f"{API}/prefill", json=body, headers=as_user("olek")).json()["data"]
    assert [r["km"] for r in data["trips"]] == [120, 80]
    assert data["trips"][1]["loaded"] == "pusty"
    assert data["total_km"] == 200
    assert data["odometer_end"] == 250_000 and data["odometer_start"] == 249_800
    assert data["vehicle"] == "MAN TGX" and data["driver_name"] == "Jan"
    bad = body | {"date_to": (day.date() - timedelta(days=1)).isoformat()}
    assert client.post(f"{API}/prefill", json=bad, headers=as_user("olek")).status_code == 422


def test_documents_numbering_permissions_and_exports(client, company):
    cid = company["id"]
    body = {
        "kind": "cmr",
        "company_id": cid,
        "vehicle_id": company["tractor"],
        "data": {"sender": "Nadawca ąę", "goods": [{"packages": 3, "bogus": 1}], "extra": "x"},
    }
    first = client.post(f"{API}/documents", json=body, headers=as_user("jan"))
    assert first.status_code == 201, first.text
    doc = first.json()
    month = f"{datetime.now(UTC):%Y/%m}"
    assert doc["number"] == f"CMR/{month}/0001"
    assert doc["data"] == {"sender": "Nadawca ąę", "goods": [{"packages": 3}]}
    assert doc["created_by_name"] == "Jan"
    second = client.post(f"{API}/documents", json=body, headers=as_user("olek")).json()
    assert second["number"] == f"CMR/{month}/0002"
    order = client.post(
        f"{API}/documents", json=body | {"kind": "transport_order"}, headers=as_user("olek")
    ).json()
    assert order["number"] == f"ZT/{month}/0001"

    listed = client.get(f"{API}/documents", params={"company_id": cid, "kind": "cmr"},
                        headers=as_user("jan")).json()  # fmt: skip
    assert {d["id"] for d in listed} == {doc["id"], second["id"]}
    assert client.get(f"{API}/documents/{doc['id']}", headers=as_user("obcy")).status_code == 404

    # Kierowca poprawia swój dokument, nie cudzy.
    change = {"data": {"sender": "Inny"}, "vehicle_id": company["tractor"]}
    assert client.put(f"{API}/documents/{second['id']}", json=change,
                      headers=as_user("jan")).status_code == 403  # fmt: skip
    updated = client.put(f"{API}/documents/{doc['id']}", json=change, headers=as_user("jan"))
    assert updated.json()["data"] == {"sender": "Inny"}

    printed = client.get(f"{API}/documents/{doc['id']}/pdf", headers=as_user("jan"))
    assert printed.status_code == 200
    assert printed.headers["content-type"] == "application/pdf"
    assert printed.content.startswith(b"%PDF-1.4") and printed.content.endswith(b"%%EOF\n")
    page = client.get(f"{API}/documents/{doc['id']}/html", headers=as_user("jan")).json()
    assert "Inny" in page["html"] and page["filename"] == f"CMR_{month.replace('/', '_')}_0001"
    link = client.post(f"{API}/documents/{doc['id']}/link", headers=as_user("jan")).json()
    shared = client.get(link["path"])
    assert shared.status_code == 200 and shared.content.startswith(b"%PDF")

    assert client.delete(f"{API}/documents/{second['id']}",
                         headers=as_user("jan")).status_code == 403  # fmt: skip
    assert client.delete(f"{API}/documents/{second['id']}",
                         headers=as_user("olek")).status_code == 204  # fmt: skip
    third = client.post(f"{API}/documents", json=body, headers=as_user("olek")).json()
    assert third["number"] == f"CMR/{month}/0002"
    bad = body | {"kind": "nope"}
    assert client.post(f"{API}/documents", json=bad, headers=as_user("olek")).status_code == 404


def _streams(data: bytes) -> list[bytes]:
    return [
        zlib.decompress(m.group(1))
        for m in re.finditer(rb"/FlateDecode >>\nstream\n(.*?)\nendstream", data, re.DOTALL)
    ]


def test_pdf_encodes_polish_letters_and_breaks_pages(texts):
    assert pdf.encode("Zażółć gęślą jaźń") == "Zażółć gęślą jaźń".encode("cp1250")
    assert pdf.encode("ŁĄ € 中") == "ŁĄ € ?".encode("cp1250")
    assert pdf.wrap("aaa bbb ccc", 10, pdf.text_width("aaa bbb", 10)) == ["aaa bbb", "ccc"]
    assert len(pdf.wrap("x" * 200, 10, 50)) > 1
    rows = [{"date": "2026-11-05", "km": i} for i in range(120)]
    with i18n.use("pl"):
        data = to_pdf(Doc(KINDS["road_card"], "KD/2026/11/0001", {"trips": rows, "notes": "Łódź"}))
    assert data.count(b"/Type /Page ") >= 3
    text = b"".join(_streams(data))
    assert "Łódź".encode("cp1250") in text
    assert b"/lslash" in data and b"/aogonek" in data
    # xref wskazuje na początki obiektów
    xref = int(data.rsplit(b"startxref\n", 1)[1].split(b"\n")[0])
    offsets = [int(line[:10]) for line in data[xref:].split(b"\n")[3:] if line[10:17] == b" 00000 "]
    assert all(re.match(rb"\d+ 0 obj", data[o : o + 12]) for o in offsets)


def test_hidden_fields_and_terms_in_print(texts):
    doc = Doc(
        KINDS["cmr"], "CMR/1", {"sender": "<b>X</b>", "cash_on_delivery": "100"},
        fields=fields_for(KINDS["cmr"], Template(hidden=["cash_on_delivery"])), terms="Klauzula",
    )  # fmt: skip
    with i18n.use("pl"):
        page = to_html(doc)
    assert "&lt;b&gt;X&lt;/b&gt;" in page and "Klauzula" in page
    assert "Za pobraniem" not in page


def _png() -> str:
    import base64
    import io

    from PIL import Image

    out = io.BytesIO()
    Image.new("RGBA", (400, 100), (200, 0, 0, 128)).save(out, "PNG")
    return base64.b64encode(out.getvalue()).decode()


def test_company_fields_labels_and_logo_in_print(client, company):
    cid, owner = company["id"], as_user("olek")
    template = {
        "labels": {"sender": "Załadowca", "bogus": "x"},
        "hidden": ["successive_carriers"],
        "extra_fields": [
            {"label": "Nr zamówienia klienta", "type": "text", "width": 0.5},
            {"label": "Nr zamówienia klienta", "type": "number", "width": 0.25},
        ],
        "defaults": {"x_nr_zamowienia_klienta": "PO-1"},
    }
    saved = client.put(
        f"{API}/templates/cmr", params={"company_id": cid}, json=template, headers=owner
    )
    assert saved.status_code == 200, saved.text
    body = saved.json()
    keys = [x["key"] for x in body["extra_fields"]]
    assert keys == ["x_nr_zamowienia_klienta", "x_nr_zamowienia_klienta_2"]
    assert body["labels"] == {"sender": "Załadowca"}
    fields = {f["key"]: f["label"] for f in body["fields"]}
    assert fields["sender"] == "1. Załadowca" and "successive_carriers" not in fields
    assert fields["x_nr_zamowienia_klienta"] == "Nr zamówienia klienta"
    # Kierowca widzi formularz, nie zmienia szablonu.
    assert client.get(f"{API}/templates/cmr", params={"company_id": cid},
                      headers=as_user("jan")).json()["fields"] == body["fields"]  # fmt: skip
    assert client.put(f"{API}/templates/cmr", params={"company_id": cid}, json=template,
                      headers=as_user("jan")).status_code == 403  # fmt: skip

    prefilled = client.post(f"{API}/prefill", json={"kind": "cmr", "company_id": cid},
                            headers=owner).json()  # fmt: skip
    assert prefilled["data"]["x_nr_zamowienia_klienta"] == "PO-1"

    data = {"sender": "Firma A", "x_nr_zamowienia_klienta": "PO-7", "x_unknown": "z"}
    doc = client.post(f"{API}/documents", json={"kind": "cmr", "company_id": cid, "data": data},
                      headers=owner).json()  # fmt: skip
    assert doc["data"] == {"sender": "Firma A", "x_nr_zamowienia_klienta": "PO-7"}

    assert client.put(f"{API}/profile/logo", params={"company_id": cid}, json={"image": "eA=="},
                      headers=owner).status_code == 422  # fmt: skip
    assert client.put(f"{API}/profile/logo", params={"company_id": cid}, json={"image": _png()},
                      headers=as_user("jan")).status_code == 403  # fmt: skip
    logo = client.put(f"{API}/profile/logo", params={"company_id": cid}, json={"image": _png()},
                      headers=owner)  # fmt: skip
    assert logo.json()["has_logo"] is True
    image = client.get(f"{API}/profile/logo", params={"company_id": cid}, headers=as_user("jan"))
    assert image.headers["content-type"] == "image/jpeg" and image.content[:2] == b"\xff\xd8"

    page = client.get(f"{API}/documents/{doc['id']}/html", headers=owner).json()["html"]
    assert "Załadowca" in page and "PO-7" in page and "data:image/jpeg;base64," in page
    assert "Kolejni przewoźnicy" not in page
    printed = client.get(f"{API}/documents/{doc['id']}/pdf", headers=owner).content
    assert b"/Subtype /Image" in printed and b"/Im1 Do" in b"".join(_streams(printed))
    assert "Załadowca".encode("cp1250") in b"".join(_streams(printed))

    cleared = client.delete(f"{API}/profile/logo", params={"company_id": cid}, headers=owner)
    assert cleared.json()["has_logo"] is False
    assert (
        client.get(f"{API}/profile/logo", params={"company_id": cid}, headers=owner).status_code
        == 404
    )
