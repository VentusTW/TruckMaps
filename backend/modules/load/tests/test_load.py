import json
from importlib import resources

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.pool import StaticPool
from truckmaps_load.module import Item, LoadModule, PlanIn, plan

from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.config import Settings
from truckmaps.core.db import Base, Database
from truckmaps.sdk import Principal, i18n

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
