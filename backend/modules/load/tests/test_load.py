import json
from importlib import resources

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.pool import StaticPool
from truckmaps_load.module import Item, LoadModule, PlanIn, _lay, _rows, axle_loads, plan, supports

from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.config import Settings
from truckmaps.core.db import Base, Database
from truckmaps.sdk import Principal, i18n
from truckmaps.sdk.fleet import CargoInfo

# Teksty modułu bez uruchamiania aplikacji (plan liczony wprost).
for language in ("pl", "en"):
    file = resources.files("truckmaps_load") / "locales" / f"{language}.json"
    i18n.register(language, json.loads(file.read_text("utf-8")))


def make(items, **extra) -> PlanIn:
    return PlanIn(vehicle_id="v", items=[Item(**i) for i in items], **extra)


def test_full_semitrailer_of_euro_and_industrial_pallets():
    euro = plan(make([{"kind": "euro", "count": 33, "weight_kg": 500}]), 13.6, 2.48, 24_000)
    assert (euro.unplaced, euro.used_length_m, euro.ldm, euro.fits) == (0, 13.2, 13.64, True)
    assert len(euro.rows) == 11 and {p.width_m for p in euro.placed} == {0.8}

    industrial = plan(
        make([{"kind": "industrial", "count": 26, "weight_kg": 500}]), 13.6, 2.48, None
    )
    assert (industrial.unplaced, industrial.used_length_m) == (0, 13.0)  # 2 w poprzek w rzędzie 1 m
    too_many = plan(make([{"kind": "euro", "count": 36, "weight_kg": 500}]), 13.6, 2.48, None)
    assert (too_many.unplaced, too_many.fits) == (3, False)


def test_last_stop_at_the_front_weight_and_stacking():
    data = make(
        [
            {"kind": "euro", "count": 6, "weight_kg": 400, "stop": 1, "label": "Poznań"},
            {"kind": "euro", "count": 6, "weight_kg": 300, "stop": 2, "stack": 2},
        ]
    )
    result = plan(data, 13.6, 2.48, 2_000)
    front = result.placed[0]
    assert (front.item, front.stop, front.weight_kg) == (1, 2, 600)  # stos dwóch palet
    assert result.placed[-1].stop == 1  # pierwszy rozładunek przy drzwiach
    assert result.used_length_m == pytest.approx(1.2 + 2.4)
    assert result.weight_kg == 4200 and not result.fits
    assert any("ładowność" in w for w in result.warnings)
    assert any("z przodu" in w for w in result.warnings)  # cały ładunek przy ścianie czołowej


def test_straps_per_row_by_en_12195_1():
    heavy = [{"kind": "euro", "count": 3, "weight_kg": 800}]
    # 2400 kg w rzędzie, bez maty (μ 0,3), na boki 0,5 g: 1,1·2400·9,81·0,2 / (2·0,3·4000) ≈ 2,2.
    assert plan(make(heavy), 13.6, 2.48, None).rows[0].straps == 3
    # Z matą (μ 0,6) tarcie trzyma – zostaje jeden pas na rząd.
    assert plan(make(heavy, mats=True), 13.6, 2.48, None).rows[0].straps == 1
    # Bez ściany czołowej liczy się hamowanie 0,8 g: rząd 2,4 t potrzebuje 6 pasów – za dużo na
    # 1,2 m, więc plan kładzie po 2 palety w rzędzie (1,6 t – 4 pasy).
    loose = plan(make(heavy, front_wall=False), 13.6, 2.48, None)
    assert [r.straps for r in loose.rows] == [4, 2] and loose.forces.ok
    assert any("ścianę czołową" in w for w in loose.warnings)


class Verifier:
    def verify(self, token: str) -> Principal:
        if not token.startswith("user-"):
            raise InvalidToken(token)
        return Principal(subject=token.removeprefix("user-"))


def test_plan_endpoint_uses_vehicle_profile():
    database = Database(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(database.engine)
    app = create_app(
        Settings(dev_grant_all=True),
        modules=[LoadModule()],
        token_verifier=Verifier(),
        database=database,
    )
    client = TestClient(app)
    headers = {"Authorization": "Bearer user-ola"}
    trailer = {
        "name": "Naczepa", "kind": "semitrailer", "height_m": 4.0, "width_m": 2.55,
        "length_m": 13.6, "gvw_t": 39, "tare_t": 7, "axle_load_t": 9, "axle_count": 3,
        "trailer_type": "curtain", "pallet_places": 33,
    }  # fmt: skip
    vehicle = client.post("/api/vehicles", json=trailer, headers=headers).json()
    body = {"vehicle_id": vehicle["id"], "items": [{"count": 10, "weight_kg": 700}]}
    result = client.post("/api/m/load/plan", json=body, headers=headers).json()
    assert (result["deck_length_m"], result["payload_kg"], result["weight_kg"]) == (
        13.6,
        32000,
        7000,
    )
    assert result["estimated"] is True
    other = client.post(
        "/api/m/load/plan", json=body, headers={"Authorization": "Bearer user-obcy"}
    )
    assert other.status_code == 404


SEMITRAILER = CargoInfo(
    deck_length_m=13.6, payload_kg=32_000, kind="semitrailer", axle_count=3, axle_load_t=9,
    tare_kg=7_000, gvw_kg=39_000, height_m=4.0,
)  # fmt: skip


def test_heavy_short_load_is_moved_back_so_the_fifth_wheel_is_not_overloaded():
    heavy = make([{"kind": "industrial", "count": 10, "weight_kg": 2000, "height_m": 1.1}])
    # Przy ścianie czołowej 20 t w pierwszych 5 m przeciąża siodło (limit 12 t).
    laid, _, _ = _lay(_rows(heavy, 2.48), 0.0, 13.6)
    assert axle_loads(laid, supports(SEMITRAILER, 13.6))[0].over
    result = plan(heavy, 13.6, 2.48, 32_000, SEMITRAILER)
    kingpin, axles = result.axles
    assert (kingpin.name, axles.name) == ("kingpin", "trailer_axles")
    assert not kingpin.over and not axles.over and result.fits
    # Rzędy po 2 palety (4 t) nie dają się zamocować pasami bez mat – plan kładzie po jednej
    # palecie w rzędzie (10 m) z luką nad osiami: naciski, ciągnik i mocowanie w normie,
    # ładunek oparty o ścianę czołową.
    assert result.adjusted and result.offset_m == 0
    assert {
        sum(1 for p in result.placed if p.x_m == x) for x in {p.x_m for p in result.placed}
    } == {1}
    assert any(w.startswith("Luka") for w in result.warnings)
    assert result.forces.ok and all(n.ok for n in result.norms if n.id != "en12642")
    assert any(w.startswith("Ładunek ułożono tak") for w in result.warnings)
    assert not any(w.startswith("Nie da się") for w in result.warnings)
    # Z matami antypoślizgowymi wystarczą pełne rzędy (po 2), odsunięte nad osie.
    mats = plan(heavy.model_copy(update={"mats": True}), 13.6, 2.48, 32_000, SEMITRAILER)
    assert not any(w.startswith("Nie da się") for w in mats.warnings) and mats.forces.ok
    assert mats.used_length_m < 10.0
    assert result.inner_height_m == 2.7 and result.placed[0].height_m == 1.1


def test_normal_load_stays_at_the_front_wall():
    result = plan(
        make([{"kind": "euro", "count": 33, "weight_kg": 700}]), 13.6, 2.48, 32_000, SEMITRAILER
    )
    assert (result.adjusted, result.offset_m, result.placed[0].x_m) == (False, 0.0, 0.0)
    # 23,1 t ładunku ze środkiem 6,6 m od ściany i 7 t masy własnej naczepy (35% na siodle).
    assert [round(a.load_kg) for a in result.axles] == [10967, 19133]


def test_rigid_front_axle_and_stack_too_high():
    rigid = CargoInfo(
        deck_length_m=7.2, payload_kg=8_000, kind="rigid", axle_count=2, axle_load_t=11.5,
        tare_kg=10_000, gvw_kg=18_000, height_m=3.4,
    )  # fmt: skip
    data = make([{"kind": "euro", "count": 6, "weight_kg": 1000, "stack": 2, "height_m": 1.2}])
    result = plan(data, 7.2, 2.45, 8_000, rigid)
    assert [a.name for a in result.axles] == ["front_axle", "rear_axles"]
    assert any("wyższy niż przestrzeń" in w for w in result.warnings)  # 2,4 m przy 2,2 m


def test_dragged_layout_is_checked_without_rearranging():
    database = Database(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(database.engine)
    app = create_app(
        Settings(dev_grant_all=True),
        modules=[LoadModule()],
        token_verifier=Verifier(),
        database=database,
    )
    client = TestClient(app)
    headers = {"Authorization": "Bearer user-ola"}
    trailer = {
        "name": "Naczepa", "kind": "semitrailer", "height_m": 4.0, "width_m": 2.55,
        "length_m": 13.6, "gvw_t": 39, "tare_t": 7, "axle_load_t": 9, "axle_count": 3,
        "trailer_type": "curtain", "pallet_places": 33,
    }  # fmt: skip
    vehicle = client.post("/api/vehicles", json=trailer, headers=headers).json()
    items = [{"kind": "industrial", "count": 10, "weight_kg": 2000}]
    body = {"vehicle_id": vehicle["id"], "items": items}
    planned = client.post("/api/m/load/plan", json=body, headers=headers).json()
    assert planned["adjusted"] and not any(a["over"] for a in planned["axles"])

    # Kierowca układa wszystko ciasno przy ścianie czołowej – siodło przeciążone, bez przestawiania.
    laid, _, _ = _lay(_rows(make(items), 2.48), 0.0, 13.6)
    dragged = [p.model_dump() for p in laid]
    checked = client.post(
        "/api/m/load/plan/check", json=body | {"placed": dragged}, headers=headers
    ).json()
    assert checked["axles"][0]["over"] and not checked["fits"] and not checked["adjusted"]
    assert any("Przekroczony nacisk: siodło" in w for w in checked["warnings"])
    overlap = dragged[:1] + [dragged[1] | {"y_m": dragged[0]["y_m"]}] + dragged[2:]
    checked = client.post(
        "/api/m/load/plan/check", json=body | {"placed": overlap}, headers=headers
    ).json()
    assert any("nachodzi" in w for w in checked["warnings"])


def test_axles_from_vehicle_documents():
    documented = CargoInfo(
        deck_length_m=13.6, payload_kg=32_000, kind="semitrailer", axle_count=3, axle_load_t=9,
        tare_kg=7_000, gvw_kg=39_000, height_m=4.0, kingpin_m=1.2, axles_m=10.4,
    )  # fmt: skip
    kingpin, axles = supports(documented, 13.6)
    assert (kingpin.x, axles.x) == (1.2, 10.4)
    rigid = CargoInfo(
        deck_length_m=7.2, payload_kg=8_000, kind="rigid", axle_count=2, axle_load_t=11.5,
        tare_kg=10_000, gvw_kg=18_000, height_m=3.4, wheelbase_m=5.2,
    )  # fmt: skip
    assert (
        supports(rigid, 7.2)[1].x == 4.0
    )  # 5,2 m od osi przedniej, która jest 1,2 m przed skrzynią


def test_force_balance_en_12195_and_tractor_axles():
    data = make([{"kind": "euro", "count": 33, "weight_kg": 700}], body_code="XL")
    result = plan(data, 13.6, 2.48, 32_000, SEMITRAILER)
    f = result.forces
    # 23,1 t: 0,8 g → 181,3 kN, 0,5 g → 113,3 kN, tarcie μ 0,3 → 68,0 kN, reszta do przodu 113,3 kN.
    assert (f.forward_kN, f.side_kN, f.friction_kN, f.rest_forward_kN) == (
        181.3,
        113.3,
        68.0,
        113.3,
    )
    # Ściana XL: 0,5 · 32 t · g = 157,0 kN – przejmuje hamowanie; pasy tylko na boki i do tyłu:
    # rząd 2,1 t: 1,1 · 2100 · 9,81 · 0,2 / (2 · 0,3) = 755 daN → 2 pasy po 400 daN.
    assert (f.wall_kN, f.wall_holds, f.ok) == (157.0, True, True)
    assert {r.straps for r in result.rows} == {2} and f.straps == 22
    assert f.tension_daN == pytest.approx(11 * 755.4, abs=2)
    assert (result.pallet_places, result.places_used) == (33, 33)
    tr = result.tractor
    # Siodło 10 967 kg: 0,6 / 3,8 na oś przednią, reszta na napędową; ciągnik 7,3 t (70% z przodu).
    assert (tr.front_kg, tr.drive_kg, tr.gvw_kg, tr.drive_share) == (6842, 11425, 37400, 0.305)
    assert all(n.ok for n in result.norms)


def test_weak_front_wall_needs_straps_forward_or_mats():
    data = make([{"kind": "euro", "count": 33, "weight_kg": 700}], body_code="L")
    result = plan(data, 13.6, 2.48, 32_000, SEMITRAILER)
    # Kod L: najwyżej 5000 daN = 50 kN < 113,3 kN.
    # Rząd 2,1 t do przodu (0,8 g): 1888 daN – 5 pasów, za dużo na 1,2 m.
    assert (result.forces.wall_kN, result.forces.wall_holds) == (50.0, False)
    assert {r.straps for r in result.rows} == {5} and not result.forces.ok
    assert {n.id: n.ok for n in result.norms}["en12195"] is False
    assert any("Ściana czołowa" in w for w in result.warnings)
    assert any("Za dużo pasów" in w for w in result.warnings)
    # Z matami (μ 0,6) do przodu zostaje 45,3 kN – ściana L wystarcza, tarcie trzyma boki.
    mats = plan(data.model_copy(update={"mats": True}), 13.6, 2.48, 32_000, SEMITRAILER)
    assert (mats.forces.rest_forward_kN, mats.forces.wall_holds, mats.forces.ok) == (
        45.3,
        True,
        True,
    )
    assert mats.straps == 11


def test_equipment_checklist_vdi_2700():
    data = make(
        [
            {
                "kind": "custom",
                "length_m": 1.0,
                "width_m": 1.0,
                "count": 4,
                "weight_kg": 500,
                "stop": 1,
            },
            {"kind": "euro", "count": 3, "weight_kg": 500, "stop": 2},
        ],
        mats=True,
    )
    result = plan(data, 13.6, 2.48, None)
    gear = {e.id: e.required for e in result.equipment}
    # 3 rzędy po jednym pasie, 2 narożniki na pas, belka między rozładunkami, mata pod każdą
    # sztuką, poduszka w rzędach skrzyń 1 × 1 m (2 w poprzek – luka 0,48 m).
    assert gear == {"straps": 3, "edges": 6, "beams": 1, "mats": 7, "airbags": 2}
    assert (result.pallet_places, result.places_used) == (33, 7)
    assert result.tractor is None


def test_tractor_warns_about_drive_axle_share():
    from truckmaps_load.securing import tractor, tractor_problems

    light = tractor(3_000, 20_000)
    assert light.drive_share < 0.25 and tractor_problems(light) == ["drive_share"]
    heavy = tractor(14_000, 20_000)
    assert "drive" in tractor_problems(heavy)


def test_plan_pdf_is_shared_under_a_short_link():
    database = Database(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(database.engine)
    app = create_app(
        Settings(dev_grant_all=True),
        modules=[LoadModule()],
        token_verifier=Verifier(),
        database=database,
    )
    client = TestClient(app)
    headers = {"Authorization": "Bearer user-ola"}
    trailer = {
        "name": "Naczepa", "kind": "semitrailer", "height_m": 4.0, "width_m": 2.55,
        "length_m": 13.6, "gvw_t": 39, "tare_t": 7, "axle_load_t": 9, "axle_count": 3,
        "trailer_type": "curtain", "pallet_places": 33, "plate": "WN 9024X",
    }  # fmt: skip
    vehicle = client.post("/api/vehicles", json=trailer, headers=headers).json()
    body = {
        "vehicle_id": vehicle["id"], "body_code": "XL", "reference": "MT-849102",
        "items": [{"count": 18, "weight_kg": 1100}, {"count": 6, "weight_kg": 400, "stack": 2}],
        "checked": ["straps"], "approved": True,
    }  # fmt: skip
    link = client.post("/api/m/load/plan/pdf", json=body, headers=headers)
    assert link.status_code == 200 and link.json()["filename"].startswith("plan-MT-849102")
    pdf = client.get(link.json()["path"])
    assert pdf.status_code == 200 and pdf.content.startswith(b"%PDF")
