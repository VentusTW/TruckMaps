"""Opłaty drogowe i koszty (M4): paliwo po cenach w krajach na trasie i myto per kraj.

Paliwo: spalanie z profilu × własna cena pojazdu, a bez niej cena ON w kraju z Weekly Oil
Bulletin KE (rdzeń podaje ją w profilu kosztów). Myto: km płatnych dróg w kraju × stawka
z cennika operatora (``tariffs.json``) dla klasy pojazdu. Gdy stawki dla pojazdu nie znamy,
koszt pokazuje płatne km bez kwoty – nic nie zgadujemy. Każda kwota jest szacunkowa.
"""

import json
from dataclasses import dataclass
from importlib import resources

from truckmaps.sdk import (
    COST_PROVIDER,
    CoreContext,
    CostPart,
    CostProfile,
    CostVehicle,
    CountryDistance,
    Module,
)

# Klasy dróg Valhalli, które liczymy jak autostrady i drogi ekspresowe (stawka „motorway”).
FAST_ROADS = {"motorway", "trunk"}

# Waluta kraju (paliwo i myto płacone na miejscu); kraje strefy euro – EUR.
COUNTRY_CURRENCY = {
    "PL": "PLN", "CZ": "CZK", "HU": "HUF", "RO": "RON", "BG": "BGN", "SE": "SEK",
    "DK": "DKK", "CH": "CHF", "NO": "NOK", "GB": "GBP", "UA": "UAH",
}  # fmt: skip
EURO_COUNTRIES = {
    "AT", "BE", "HR", "CY", "EE", "FI", "FR", "DE", "GR", "IE", "IT", "LV", "LT", "LU",
    "MT", "NL", "PT", "SK", "SI", "ES",
}  # fmt: skip


def country_currency(country: str) -> str | None:
    return COUNTRY_CURRENCY.get(country) or ("EUR" if country in EURO_COUNTRIES else None)


def convert(amount: float, source: str, target: str, per_eur: dict[str, float]) -> float | None:
    """Przeliczenie po kursach EBC (waluta → ile za 1 €); brak kursu – ``None``."""
    if source == target:
        return amount
    if source not in per_eur or target not in per_eur:
        return None
    return amount / per_eur[source] * per_eur[target]


def _local(part: CostPart, country: str, profile: CostProfile, native: float | None = None):
    """Kwota części także w walucie kraju (obok kwoty w walucie profilu)."""
    local = country_currency(country)
    if local is None or local == profile.currency or part.unknown:
        return part
    amount = (
        native
        if native is not None
        else convert(part.amount, profile.currency, local, profile.per_eur)
    )
    if amount is None:
        return part
    return part.model_copy(update={"local_amount": amount, "local_currency": local})


def load_tariffs() -> dict:
    text = (resources.files("truckmaps_costs") / "tariffs.json").read_text("utf-8")
    return {k: v for k, v in json.loads(text).items() if not k.startswith("_")}


def _matches(rule: dict, vehicle: CostVehicle) -> bool:
    co2 = vehicle.co2_class or 1  # bez klasy CO₂ – najwyższa stawka (jak u operatorów)
    return (
        vehicle.gvw_t >= rule.get("min_gvw_t", 0)
        and vehicle.axle_count >= rule.get("min_axles", 0)
        and vehicle.axle_count <= rule.get("max_axles", 99)
        and (vehicle.emission_class in rule["euro"] if "euro" in rule else True)
        and (co2 in rule["co2"] if "co2" in rule else True)
    )


@dataclass(frozen=True)
class Toll:
    km_fast: float
    km_other: float
    amount: float | None
    """W walucie profilu; ``None`` – stawki dla pojazdu nie znamy."""
    source: str | None
    native: float | None = None
    """W walucie cennika operatora."""
    native_currency: str | None = None


def toll(country: CountryDistance, profile: CostProfile, tariffs: dict) -> Toll | None:
    """Myto w kraju; ``None``, gdy kraj bez opłat w cenniku albo trasa bez płatnych dróg."""
    tariff = tariffs.get(country.country)
    if tariff is None or profile.vehicle is None or profile.vehicle.gvw_t <= 3.5:
        return None
    tolled = tariff["tolled"]
    fast = other = 0.0
    for road in country.roads:
        if road.road_class in tolled["classes"] or (road.toll and tolled.get("osm_toll")):
            if road.road_class in FAST_ROADS:
                fast += road.km
            else:
                other += road.km
    if fast + other <= 0:
        return None
    rule = next((r for r in tariff.get("rules", []) if _matches(r, profile.vehicle)), None)
    if rule is None:
        return Toll(fast, other, None, tariff.get("calculator"))
    native = fast * rule["motorway"] + other * rule["other"]
    amount = convert(native, tariff["currency"], profile.currency, profile.per_eur)
    if amount is None:
        return Toll(fast, other, None, tariff.get("calculator"))
    return Toll(fast, other, amount, tariff.get("source"), native, tariff["currency"])


class TollAndFuelCosts:
    """``CostProvider`` z częściami kosztu: stawki, paliwo i AdBlue per kraj, myto per kraj."""

    def __init__(self, tariffs: dict) -> None:
        self._tariffs = tariffs

    def estimate(self, distance_km: float, duration_h: float, profile: CostProfile) -> float:
        return sum(p.amount for p in self.parts(distance_km, duration_h, profile))

    def parts(self, distance_km: float, duration_h: float, profile: CostProfile) -> list[CostPart]:
        parts = []
        if profile.per_km:
            parts.append(CostPart(kind="distance", amount=distance_km * profile.per_km))
        if profile.per_hour:
            parts.append(CostPart(kind="time", amount=duration_h * profile.per_hour))
        countries = profile.countries or [CountryDistance(country="", km=distance_km)]
        # Odcinki z Valhalli sumują się prawie do długości trasy; resztę dzielimy proporcjonalnie.
        known = sum(c.km for c in countries) or distance_km
        scale = distance_km / known if known else 1.0
        for country in countries:
            km = country.km * scale
            price = profile.fuel_price or profile.diesel_prices.get(country.country)
            if profile.consumption and price:
                litres = km * profile.consumption / 100
                fuel = CostPart(kind="fuel", amount=litres * price, country=country.country, km=km)
                parts.append(_local(fuel, country.country, profile))
                if profile.adblue_percent and profile.adblue_price:
                    adblue = litres * profile.adblue_percent / 100 * profile.adblue_price
                    part = CostPart(kind="adblue", amount=adblue, country=country.country, km=km)
                    parts.append(_local(part, country.country, profile))
            found = toll(country, profile, self._tariffs)
            if found is not None:
                part = CostPart(
                    kind="toll",
                    amount=found.amount or 0.0,
                    country=country.country,
                    km=round(found.km_fast + found.km_other, 1),
                    unknown=found.amount is None,
                    source=found.source,
                )
                native = (
                    found.native
                    if found.native_currency == country_currency(country.country)
                    else None
                )
                parts.append(_local(part, country.country, profile, native))
        return parts


class CostsModule(Module):
    id = "costs"
    name = "Opłaty drogowe i koszty"
    version = "0.1.0"
    requires_core = ">=0.1,<1.0"

    def register(self, ctx: CoreContext) -> None:
        ctx.extensions.provide(COST_PROVIDER, TollAndFuelCosts(load_tariffs()), priority=10)
