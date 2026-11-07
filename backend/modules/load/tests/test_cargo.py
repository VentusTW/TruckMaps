"""Rodzaje towaru: katalog, tarcie i mocowanie wg towaru, zabudowa, własne rodzaje."""

import json
from importlib import resources

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.pool import StaticPool
from truckmaps_load.cargo import BUILT_IN, CATALOG, GROUPS
from truckmaps_load.module import Base as LoadBase
from truckmaps_load.module import Item, LoadModule, PlanIn, plan

from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.config import Settings
from truckmaps.core.db import Base, Database
from truckmaps.sdk import Principal, i18n
from truckmaps.sdk.fleet import BODY_GROUP, BODY_GROUPS, CargoInfo

for language in ("pl", "en"):
    file = resources.files("truckmaps_load") / "locales" / f"{language}.json"
    i18n.register(language, json.loads(file.read_text("utf-8")))

SEMITRAILER = dict(
    deck_length_m=13.6, payload_kg=32_000, kind="semitrailer", axle_count=3, axle_load_t=9,
    tare_kg=7_000, gvw_kg=39_000, height_m=4.0,
)  # fmt: skip


def trailer(body: str) -> CargoInfo:
    return CargoInfo(**SEMITRAILER, body=body)


def make(items, **extra) -> PlanIn:
    return PlanIn(vehicle_id="v", items=[Item(**i) for i in items], **extra)


def coil(count=1, **extra):
    c = BUILT_IN["coil_eye_horizontal"]
    return {"kind": "custom", "cargo": c.id, "count": count, "weight_kg": c.weight_kg} | extra


def test_catalog_is_large_grouped_and_translated():
    assert len(CATALOG) >= 60 and len({c.id for c in CATALOG}) == len(CATALOG)
    assert {c.group for c in CATALOG} == set(GROUPS)
    pl = json.loads((resources.files("truckmaps_load") / "locales" / "pl.json").read_text("utf-8"))
    en = json.loads((resources.files("truckmaps_load") / "locales" / "en.json").read_text("utf-8"))
    keys = [f"load.cargo.{c.id}" for c in CATALOG] + [f"load.cargo_group.{g}" for g in GROUPS]
    keys += [f"load.body_group.{g}" for g in BODY_GROUPS] + [f"load.body.{b}" for b in BODY_GROUP]
    assert [k for k in keys if k not in pl or k not in en] == []
    # Każdy rodzaj zabudowy w jednej grupie; zbiorniki i chłodnie w osobnych zestawach.
    assert len(BODY_GROUP) == sum(len(b) for b in BODY_GROUPS.values()) >= 30


def test_steel_coil_needs_coil_body_chains_and_chocks():
    on_curtain = plan(make([coil(1)]), 13.6, 2.48, 32_000, trailer("curtain"))
    assert any("nie wozi się zabudową" in w and "plandeka" in w for w in on_curtain.warnings)
    assert any("ładunek skupiony (10 t na metr)" in w for w in on_curtain.warnings)
    gear = {e.id: e.required for e in on_curtain.equipment}
    # Mocowanie bezpośrednie: 4 odciągi na krąg, 2 kliny na krąg, bez pasów dociskowych.
    assert (gear["chains"], gear["chocks"], gear["straps"]) == (4, 2, 0)
    assert {r.method for r in on_curtain.rows} == {"direct"} and on_curtain.straps == 0
    # 15 t na 1,5 m przeciąża siodło przy ścianie – plan odsuwa krąg nad osie, więc hamowanie
    # (0,8 g) też trzymają odciągi: 1,25 · 15000 · 9,81 · (0,8 − 0,2) / (2 · (0,2 · 0,707 + 0,612))
    # = 7320 daN na odciąg – więcej niż łańcuch 5000 daN.
    assert on_curtain.offset_m > 0
    assert on_curtain.forces.lashing_daN == pytest.approx(7320, abs=2)
    assert on_curtain.forces.lashings == 4 and not on_curtain.forces.ok
    assert any("LC 7320 daN" in w for w in on_curtain.warnings)

    on_coil = plan(make([coil(1)], mats=True), 13.6, 2.48, 32_000, trailer("coil"))
    assert not any("nie wozi się" in w for w in on_coil.warnings)
    # Maty gumowe (μ 0,6): na boki i do tyłu trzyma tarcie, do przodu zostaje 0,2 g:
    # 1,25 · 15000 · 9,81 · 0,2 / (2 · (0,6 · 0,707 + 0,612)) = 1774 daN – łańcuch wystarcza.
    assert on_coil.forces.lashing_daN == pytest.approx(1774, abs=2)
    assert on_coil.forces.ok
    assert on_coil.placed[0].height_m == 1.8  # wysokość z katalogu (średnica)


def test_hay_bales_net_stack_limit_and_friction():
    hay = BUILT_IN["hay_square"]
    item = {"kind": "custom", "cargo": hay.id, "count": 24, "weight_kg": 450, "stack": 4}
    result = plan(make([item]), 13.6, 2.48, 32_000, trailer("flatbed"))
    assert any("najwyżej 3 w stosie" in w for w in result.warnings)
    gear = {e.id: e.required for e in result.equipment}
    # 6 stosów po 2 w rzędzie 2,4 m wzdłuż… 3 rzędy × 2,4 m = 7,2 m → 2 siatki.
    assert gear["net"] == 2 and gear["straps"] > 0
    assert result.forces.mu == 0.4  # bela – sklejka
    assert not any("nie wozi się" in w for w in result.warnings)


def test_bulk_in_tipper_has_no_straps():
    sand = {"kind": "custom", "cargo": "sand_gravel", "count": 1, "weight_kg": 24_000}
    result = plan(make([sand]), 13.6, 2.48, 32_000, trailer("tipper"))
    assert (result.straps, result.rows[0].method, result.forces.tension_daN) == (0, "none", 0)
    assert not any("nie wozi się" in w for w in result.warnings)
    on_curtain = plan(make([sand]), 13.6, 2.48, 32_000, trailer("curtain"))
    assert any("wywrotka" in w for w in on_curtain.warnings)


def test_pallets_without_cargo_type_unchanged():
    euro = [{"kind": "euro", "count": 33, "weight_kg": 700}]
    a = plan(make(euro), 13.6, 2.48, 32_000, trailer("curtain"))
    b = plan(make([dict(euro[0], cargo="pallet_euro")]), 13.6, 2.48, 32_000, trailer("curtain"))
    assert a.straps == b.straps == 22 and a.forces == b.forces


class Verifier:
    def verify(self, token: str) -> Principal:
        if not token.startswith("user-"):
            raise InvalidToken(token)
        return Principal(subject=token.removeprefix("user-"))


def test_custom_cargo_types_per_user_and_body_types():
    database = Database(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(database.engine)
    LoadBase.metadata.create_all(database.engine)
    app = create_app(
        Settings(dev_grant_all=True), modules=[LoadModule()], token_verifier=Verifier(),
        database=database,
    )  # fmt: skip
    client = TestClient(app)
    ola = {"Authorization": "Bearer user-ola", "Accept-Language": "pl"}
    catalog = client.get("/api/m/load/cargo-types", headers=ola).json()
    assert len(catalog["types"]) == len(CATALOG) and len(catalog["groups"]) == len(GROUPS)
    hay = next(c for c in catalog["types"] if c["id"] == "hay_round")
    assert (hay["name"], hay["shape"], hay["custom"]) == ("Bele siana okrągłe", "bale_round", False)

    mine = {
        "name": "Skrzynie z gumą", "group": "packages", "shape": "box", "length_m": 1.2,
        "width_m": 1.2, "height_m": 1.0, "weight_kg": 900, "mu": 0.6, "stack": 2,
    }  # fmt: skip
    created = client.post("/api/m/load/cargo-types", json=mine, headers=ola)
    assert created.status_code == 201 and created.json()["custom"] is True
    custom_id = created.json()["id"]
    assert custom_id in {
        c["id"] for c in client.get("/api/m/load/cargo-types", headers=ola).json()["types"]
    }
    other = {"Authorization": "Bearer user-obcy"}
    assert custom_id not in {
        c["id"] for c in client.get("/api/m/load/cargo-types", headers=other).json()["types"]
    }
    assert client.delete(f"/api/m/load/cargo-types/{custom_id}", headers=other).status_code == 404
    bad = client.post("/api/m/load/cargo-types", json=mine | {"bodies": ["rakieta"]}, headers=ola)
    assert bad.status_code == 422

    # Nowe rodzaje zabudowy: coil przyjęty, cysterna spożywcza bez miejsc paletowych.
    base = {
        "name": "Naczepa", "kind": "semitrailer", "height_m": 4.0, "width_m": 2.55,
        "length_m": 13.6, "gvw_t": 39, "tare_t": 7, "axle_load_t": 9, "axle_count": 3,
        "pallet_places": 33,
    }  # fmt: skip
    coil_trailer = client.post(
        "/api/vehicles", json=base | {"trailer_type": "coil"}, headers=ola
    ).json()
    assert coil_trailer["trailer_type"] == "coil" and coil_trailer["pallet_places"] == 33
    tank = client.post(
        "/api/vehicles", json=base | {"trailer_type": "tanker_food"}, headers=ola
    ).json()
    assert (tank["trailer_type"], tank["pallet_places"]) == ("tanker_food", None)

    # Plan z własnym rodzajem (μ 0,6 – tarcie trzyma) i kręgiem na naczepie coil.
    body = {
        "vehicle_id": coil_trailer["id"],
        "items": [
            {"kind": "custom", "cargo": custom_id, "count": 4, "weight_kg": 900},
            coil(1),
        ],
    }
    result = client.post("/api/m/load/plan", json=body, headers=ola).json()
    assert result["forces"]["mu"] == 0.2  # najsłabsze tarcie – krąg
    assert not any("nie wozi się" in w for w in result["warnings"])
    rows = {r["method"] for r in result["rows"]}
    assert rows == {"top", "direct"}
    assert client.delete(f"/api/m/load/cargo-types/{custom_id}", headers=ola).status_code == 204


def test_heavy_coil_goes_over_the_axles_with_a_gap_pallets_stay_at_the_front_wall():
    items = [{"kind": "euro", "count": 12, "weight_kg": 400, "stop": 2}, coil(1, stop=1)]
    result = plan(make(items, mats=True), 13.6, 2.48, 32_000, trailer("coil"))
    pallets = sorted({p.x_m for p in result.placed if p.item == 0})
    ring = next(p for p in result.placed if p.item == 1)
    # Palety od ściany czołowej, luka między rzędami – krąg bliżej osi naczepy.
    assert pallets[0] == 0 and result.offset_m == 0 and ring.x_m >= 6.0
    rows = sorted([*pallets, ring.x_m])
    assert any(b - a >= 2.2 for a, b in zip(rows, rows[1:], strict=False))
    assert any(w.startswith("Luka") and "belką" in w for w in result.warnings)
    assert {e.id: e.required for e in result.equipment}["beams"] >= 2  # rozładunek + luka
    assert not any(w.startswith("Nie da się") for w in result.warnings)
    assert all(n.ok for n in result.norms if n.id != "en12642") and result.fits


def test_rows_with_fewer_pieces_when_full_rows_cannot_be_strapped():
    items = [
        {"kind": "euro", "count": 10, "weight_kg": 1500, "stop": 1},
        {"kind": "euro", "count": 10, "weight_kg": 200, "stop": 2},
    ]
    result = plan(make(items), 13.6, 2.48, 32_000, trailer("curtain"))
    heavy_rows = {}
    for p in result.placed:
        if p.item == 0:
            heavy_rows[p.x_m] = heavy_rows.get(p.x_m, 0) + 1
    # 3 palety po 1,5 t w rzędzie to 5 pasów na 1,2 m – za dużo; po 2 w rzędzie wystarczą 3.
    assert set(heavy_rows.values()) == {2}
    assert result.forces.ok and result.fits
    assert not any(w.startswith("Nie da się") for w in result.warnings)


def test_impossible_load_says_so_first():
    # 33 palety po 900 kg: z ciągnikiem i naczepą ponad 40 t DMC – żadne ułożenie nie pomoże.
    result = plan(
        make([{"kind": "euro", "count": 33, "weight_kg": 900}]),
        13.6,
        2.48,
        32_000,
        trailer("curtain"),
    )
    assert result.warnings[0].startswith("Nie da się ułożyć")
    assert any("Masa całkowita zestawu" in w for w in result.warnings)


HEAVY = [{"kind": "industrial", "count": 10, "weight_kg": 2000, "height_m": 1.1}]


def test_own_equipment_proposal_uses_mats_instead_of_missing_straps():
    # Bez mat potrzeba 20 pasów (po palecie w rzędzie); użytkownik ma 10 pasów i 20 mat.
    have = {"straps": 10, "edges": 20, "mats": 20, "beams": 2, "airbags": 6}
    result = plan(make(HEAVY, available=have), 13.6, 2.48, 32_000, trailer("curtain"))
    assert result.mats and result.shortages == {}
    assert result.warnings[0].startswith("Propozycja: użyj mat antypoślizgowych (10 szt., masz 20)")
    assert result.straps <= 10 and result.forces.ok
    assert not any(w.startswith("Nie da się") for w in result.warnings)
    # Bez ograniczeń sprzętu – jak dotąd: bez mat, więcej pasów.
    free = plan(make(HEAVY), 13.6, 2.48, 32_000, trailer("curtain"))
    assert not free.mats and free.straps > 10


def test_own_equipment_shortages_are_reported():
    have = {"straps": 2, "edges": 4}
    result = plan(make(HEAVY, available=have), 13.6, 2.48, 32_000, trailer("curtain"))
    assert result.warnings[0].startswith("Nie da się ułożyć")
    assert result.shortages["straps"] > 0 and "mats" not in result.shortages
    assert any(
        w.startswith("Brakuje sprzętu") and "Pasy transportowe" in w for w in result.warnings
    )


def test_equipment_is_saved_per_user():
    database = Database(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(database.engine)
    LoadBase.metadata.create_all(database.engine)
    app = create_app(
        Settings(dev_grant_all=True), modules=[LoadModule()], token_verifier=Verifier(),
        database=database,
    )  # fmt: skip
    client = TestClient(app)
    ola = {"Authorization": "Bearer user-ola"}
    assert client.get("/api/m/load/equipment", headers=ola).json() == {
        "items": {},
        "enabled": False,
    }
    saved = {"items": {"straps": 16, "mats": 30, "chains": 4}, "enabled": True}
    assert client.put("/api/m/load/equipment", json=saved, headers=ola).json() == saved
    assert client.get("/api/m/load/equipment", headers=ola).json() == saved
    other = {"Authorization": "Bearer user-obcy"}
    assert client.get("/api/m/load/equipment", headers=other).json()["enabled"] is False
    bad = client.put("/api/m/load/equipment", json={"items": {"rakieta": 1}}, headers=ola)
    assert bad.status_code == 422
