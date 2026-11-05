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
    # Bez ściany czołowej liczy się hamowanie 0,8 g.
    loose = plan(make(heavy, front_wall=False), 13.6, 2.48, None)
    assert loose.rows[0].straps == 6
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
    assert result.adjusted and result.offset_m == pytest.approx(3.25, abs=0.06)
    assert any("odsunięty od ściany czołowej" in w for w in result.warnings)
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

    # Kierowca przeciąga wszystko do ściany czołowej – siodło przeciążone, bez przestawiania.
    first = min(p["x_m"] for p in planned["placed"])
    dragged = [p | {"x_m": round(p["x_m"] - first, 2)} for p in planned["placed"]]
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
