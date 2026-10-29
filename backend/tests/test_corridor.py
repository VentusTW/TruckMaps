from fastapi.testclient import TestClient

from truckmaps.core.app import create_app
from truckmaps.core.auth import InvalidToken
from truckmaps.core.config import Settings
from truckmaps.core.corridor import build_corridor, check_position
from truckmaps.core.polyline import encode_polyline6
from truckmaps.core.restrictions import Restriction
from truckmaps.core.vehicles import VehicleIn
from truckmaps.sdk import Principal

TRUCK = VehicleIn(
    name="Zestaw", height_m=4.0, width_m=2.55, length_m=16.5, weight_t=40, gvw_t=40,
    axle_load_t=11.5, axle_count=5,
)  # fmt: skip
# Trasa ze wschodu na zachód wzdłuż równoleżnika 50° (ok. 7 km).
ROUTE = [(20.90 + i * 0.01, 50.0) for i in range(11)]


def way(osm_id, kind, value, raw, points):
    lons, lats = [p[0] for p in points], [p[1] for p in points]
    return Restriction(
        osm_type="way", osm_id=osm_id, kind=kind, value=value, raw=raw,
        line=encode_polyline6(points),
        min_lat=min(lats), max_lat=max(lats), min_lon=min(lons), max_lon=max(lons),
        source="osm", source_date="2026-10-29",
    )  # fmt: skip


def add_restrictions(database):
    # Boczna droga z wiaduktem 3,8 m odchodząca od trasy na północ (100–600 m od trasy).
    low_bridge = way(1, "height", 3.8, "maxheight=3.8", [(20.95, 50.001), (20.95, 50.0055)])
    # Droga 4,5 m – dla zestawu bez znaczenia, nie trafia do korytarza.
    high = way(2, "height", 4.5, "maxheight=4.5", [(20.96, 50.001), (20.96, 50.003)])
    # Droga z zakazem daleko od trasy (ok. 5,5 km na północ) – poza korytarzem.
    far = way(3, "hgv_no", None, "hgv=no", [(20.95, 50.05), (20.95, 50.06)])
    # Szerokość drogi to kontekst oceny, nie ograniczenie – nie trafia do korytarza.
    context = way(4, "road_width", 3.0, "width=3", [(20.97, 50.0), (20.98, 50.0)])
    gate = Restriction(
        osm_type="node", osm_id=5, kind="height", value=3.5, raw="maxheight=3.5",
        lat=50.0004, lon=20.93, min_lat=50.0004, max_lat=50.0004, min_lon=20.93, max_lon=20.93,
        source="osm", source_date="2026-10-29",
    )  # fmt: skip
    with database.session() as db:
        db.add_all([low_bridge, high, far, context, gate])
        db.commit()


def test_corridor_keeps_only_restrictions_near_route_that_matter_for_vehicle(database):
    add_restrictions(database)
    with database.session() as db:
        corridor = build_corridor(db, ROUTE, TRUCK, buffer_m=500)

    assert sorted((i.kind, i.level, i.limit) for i in corridor.items) == [
        ("height", "red", "3,5 m"),
        ("height", "red", "3,8 m"),
    ]
    assert corridor.vehicle.height_m == 4.0


def test_position_check_works_without_network(database):
    add_restrictions(database)
    with database.session() as db:
        corridor = build_corridor(db, ROUTE, TRUCK, buffer_m=500)

    # Na trasie – bez alarmu.
    assert check_position(corridor, 20.951, 50.0001).on_route
    # Zjazd w boczną drogę z wiaduktem 3,8 m – alarm.
    off = check_position(corridor, 20.9501, 50.004)
    assert not off.on_route
    assert off.alarm is not None and off.alarm.limit == "3,8 m"
    # Poza trasą, ale nie na drodze nieprzejezdnej – bez alarmu.
    elsewhere = check_position(corridor, 20.92, 50.004)
    assert (elsewhere.on_route, elsewhere.alarm) == (False, None)


class FakeVerifier:
    def verify(self, token: str) -> Principal:
        if not token.startswith("user-"):
            raise InvalidToken(token)
        return Principal(subject=token.removeprefix("user-"))


def test_corridor_endpoint_is_compressed_and_scoped_to_vehicle_owner(database):
    add_restrictions(database)
    client = TestClient(
        create_app(Settings(), modules=[], token_verifier=FakeVerifier(), database=database)
    )
    vehicle = {
        "name": "Zestaw", "height_m": 4.0, "width_m": 2.55, "length_m": 16.5, "weight_t": 40,
        "axle_load_t": 11.5, "axle_count": 5,
    }  # fmt: skip
    anna = {"Authorization": "Bearer user-anna"}
    vehicle_id = client.post("/api/vehicles", json=vehicle, headers=anna).json()["id"]
    body = {"vehicle_id": vehicle_id, "route": encode_polyline6(ROUTE)}

    response = client.post("/api/corridor", json=body, headers=anna)

    assert response.status_code == 200
    assert len(response.json()["items"]) == 2
    other = client.post("/api/corridor", json=body, headers={"Authorization": "Bearer user-bob"})
    assert other.status_code == 404
    bad = client.post("/api/corridor", json={**body, "route": "?"}, headers=anna)
    assert bad.status_code == 422
