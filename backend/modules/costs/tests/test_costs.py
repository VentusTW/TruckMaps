import pytest
from truckmaps_costs.module import CostsModule, TollAndFuelCosts, load_tariffs

from truckmaps.core.costs import countries
from truckmaps.core.route_analysis import RouteEdge
from truckmaps.sdk import CostProfile, CostVehicle

TRACTOR = CostVehicle(
    kind="combination", gvw_t=40, axle_count=5, emission_class="euro6", co2_class=1
)


def edge(country: str, km: float, road_class: str = "motorway", toll: bool = False):
    return RouteEdge(
        way_id=1, begin_index=0, end_index=1, road_class=road_class, country=country,
        length_km=km, toll=toll,
    )  # fmt: skip


@pytest.fixture
def provider():
    return TollAndFuelCosts(load_tariffs())


def by_kind(parts, kind):
    return {p.country: p for p in parts if p.kind == kind}


def test_fuel_by_country_prices_and_tolls_per_country(provider):
    route = countries(
        [
            edge("PL", 100),
            edge("PL", 20, "secondary"),
            edge("DE", 200),
            edge("DE", 30, "primary"),
            edge("CZ", 50),
        ]
    )
    profile = CostProfile(
        per_km=0.1,
        per_hour=0,
        currency="EUR",
        consumption=30,
        adblue_percent=5,
        adblue_price=0.5,
        vehicle=TRACTOR,
        countries=route,
        diesel_prices={"PL": 1.5, "DE": 2.0, "CZ": 1.8},
        per_eur={"EUR": 1.0, "PLN": 4.0},
    )
    parts = provider.parts(400, 5, profile)
    fuel = by_kind(parts, "fuel")
    assert fuel["PL"].amount == pytest.approx(120 * 0.3 * 1.5)
    assert fuel["DE"].amount == pytest.approx(230 * 0.3 * 2.0)
    assert by_kind(parts, "adblue")["CZ"].amount == pytest.approx(50 * 0.3 * 0.05 * 0.5)

    tolls = by_kind(parts, "toll")
    # PL: tylko autostrada (0,56 zł/km), droga wojewódzka bez opłat; zł → euro po kursie.
    assert (tolls["PL"].km, tolls["PL"].amount) == (100, pytest.approx(100 * 0.56 / 4))
    # DE: autostrada i droga krajowa (Bundesstraße).
    assert tolls["DE"].amount == pytest.approx(230 * 0.348)
    # CZ: płatne km bez kwoty – stawki nie znamy, kalkulator operatora.
    assert (tolls["CZ"].unknown, tolls["CZ"].amount, tolls["CZ"].km) == (True, 0, 50)
    assert tolls["CZ"].source == "https://myto.gov.cz/"
    assert provider.estimate(400, 5, profile) == pytest.approx(sum(p.amount for p in parts))
    assert by_kind(parts, "distance")[""].amount == pytest.approx(40)


def test_own_fuel_price_wins_and_unknown_vehicle_class_has_no_toll_amount(provider):
    old = TRACTOR.model_copy(update={"emission_class": "euro5"})
    profile = CostProfile(
        per_km=0,
        consumption=25,
        fuel_price=1.2,
        vehicle=old,
        countries=countries([edge("DE", 100)]),
        diesel_prices={"DE": 2.0},
    )
    parts = provider.parts(100, 1, profile)
    assert by_kind(parts, "fuel")["DE"].amount == pytest.approx(100 * 0.25 * 1.2)
    assert by_kind(parts, "toll")["DE"].unknown is True


def test_light_van_and_route_without_countries(provider):
    van = CostVehicle(kind="van", gvw_t=3.5, axle_count=2, emission_class="euro6")
    profile = CostProfile(per_km=0, consumption=10, fuel_price=1.5, vehicle=van)
    parts = provider.parts(100, 1, profile)
    assert [p.kind for p in parts] == ["fuel"]
    assert parts[0].amount == pytest.approx(15)


def test_module_provides_cost_provider_with_priority():
    module = CostsModule()
    assert module.id == "costs"


def test_route_cost_from_api_with_bulletin_prices_and_tolls():
    from datetime import date
    from pathlib import Path

    from fastapi.testclient import TestClient
    from sqlalchemy.pool import StaticPool

    from truckmaps.core import fuel_prices
    from truckmaps.core.app import create_app
    from truckmaps.core.auth import InvalidToken
    from truckmaps.core.config import Settings
    from truckmaps.core.currency import store_rates
    from truckmaps.core.db import Base, Database
    from truckmaps.core.routing import Route
    from truckmaps.sdk import Principal

    class Verifier:
        def verify(self, token: str) -> Principal:
            if not token.startswith("user-"):
                raise InvalidToken(token)
            return Principal(subject=token.removeprefix("user-"))

    class Router:
        def locate(self, stops, vehicle):
            return [(p, 0.0) for p in stops]

        def route(self, stops, vehicle, exclude=None, alternates=0) -> Route:
            return Route(
                distance_km=300.0,
                duration_min=200.0,
                geometry=[(p.lon, p.lat) for p in stops],
                edges=[edge("PL", 100), edge("DE", 200)],
            )

    database = Database(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(database.engine)
    bulletin = Path(__file__).parents[3] / "tests" / "data" / "weekly_oil_bulletin.xlsx"
    with database.session() as db:
        fuel_prices.store(db, *fuel_prices.parse_bulletin(bulletin.read_bytes()))
        store_rates(db, date(2026, 10, 28), {"PLN": 4.25})
    app = create_app(
        Settings(dev_grant_all=True),
        modules=[CostsModule()],
        token_verifier=Verifier(),
        database=database,
        router=Router(),
    )
    client = TestClient(app)
    headers = {"Authorization": "Bearer user-ola"}
    truck = {
        "name": "Zestaw", "kind": "combination", "height_m": 4.0, "width_m": 2.55,
        "length_m": 16.5, "weight_t": 40, "axle_load_t": 11.5, "axle_count": 5,
        "emission_class": "euro6", "co2_class": 1, "fuel_type": "diesel",
        "consumption_loaded": 30, "cost_currency": "EUR",
    }  # fmt: skip
    vehicle = client.post("/api/vehicles", json=truck, headers=headers).json()
    client.put("/api/me/settings", json={"currency": "EUR"}, headers=headers)
    response = client.post(
        "/api/routes",
        json={
            "vehicle_id": vehicle["id"],
            "origin": {"lat": 52.4, "lon": 16.9},
            "destination": {"lat": 52.5, "lon": 13.4},
        },
        headers=headers,
    )
    assert response.status_code == 200, response.json()
    cost = response.json()["cost"]
    assert (cost["provider"], cost["fuel_prices_day"]) == ("costs", "2026-10-26")
    parts = {(p["kind"], p["country"]): p for p in cost["parts"]}
    assert parts[("fuel", "PL")]["amount"] == pytest.approx(30 * 1.7812, abs=0.01)
    assert parts[("fuel", "DE")]["amount"] == pytest.approx(60 * 2.298, abs=0.01)
    assert parts[("toll", "PL")]["amount"] == pytest.approx(100 * 0.56 / 4.25, abs=0.01)
    assert parts[("toll", "DE")]["amount"] == pytest.approx(200 * 0.348, abs=0.01)
    assert cost["amount"] == pytest.approx(sum(p["amount"] for p in cost["parts"]), abs=0.05)
