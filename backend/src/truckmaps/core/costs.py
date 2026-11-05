"""Profile kosztów: stawki za km i za godzinę pojazdu albo firmy i szacunkowy koszt trasy.

Stawka pojazdu ma pierwszeństwo, brakującą bierzemy z firmy. Paliwo i AdBlue liczymy ze
spalania i własnych cen pojazdu – wtedy stawka za km to pozostałe koszty eksploatacji.
Każda stawka jest w walucie swojego właściciela (pojazdu albo firmy); koszt pokazujemy
w walucie wybranej przez użytkownika, przeliczając po kursie EBC. Sam koszt liczy gniazdo
``COST_PROVIDER`` – w rdzeniu prosto (km × stawka/km + h × stawka/h + paliwo z własnych cen);
moduł Opłaty drogowe i koszty podmieni je na dokładniejsze (ceny paliwa i myto per kraj).
"""

from collections.abc import Callable
from datetime import date
from typing import Literal

from pydantic import BaseModel, Field

from truckmaps.core.currency import BASE, Currency, Rates
from truckmaps.core.extensions import ExtensionRegistry
from truckmaps.core.fuel_prices import Prices
from truckmaps.sdk import (
    COST_PROVIDER,
    CostBreakdown,
    CostPart,
    CostProfile,
    CostVehicle,
    CountryDistance,
    RoadKm,
    fuel_costs,
)

# Zakresy obejmują waluty o małej wartości jednostki (1 km zestawu to kilkaset forintów).
PerKm = Field(
    default=None, ge=0, le=100_000, description="Koszt eksploatacji za kilometr", examples=[4.5]
)
PerHour = Field(
    default=None, ge=0, le=10_000_000, description="Koszt za godzinę jazdy, np. kierowca"
)


class CostRates(BaseModel):
    cost_per_km: float | None = PerKm
    cost_per_hour: float | None = PerHour
    cost_currency: Currency = Field(default=BASE, description="Waluta stawek")


class RouteCost(BaseModel):
    """Szacunkowy koszt przejazdu – zawsze pokazywany jako „≈”, nigdy jako kwota pewna."""

    amount: float
    currency: str
    per_km: float
    per_hour: float
    """Stawki użyte do wyliczenia, w walucie ``currency``."""
    fuel: float | None = None
    """Paliwo ze spalania i ceny z profilu pojazdu (część ``amount``); ``None`` – nie liczone."""
    adblue: float | None = None
    """AdBlue (część ``amount``); ``None`` – nie liczone."""
    consumption: float | None = None
    """Spalanie użyte do wyliczenia, na 100 km."""
    parts: list[CostPart] = []
    """Części kosztu (paliwo i myto per kraj), gdy liczy je moduł kosztów."""
    fuel_prices_day: date | None = None
    """Tydzień cen ON z biuletynu KE, gdy z nich liczono paliwo."""
    source: Literal["vehicle", "company", "mixed"]
    """Skąd stawki: z pojazdu, z firmy albo częściowo z obu."""
    rates_currencies: list[str]
    """Waluty, w których stawki wpisano."""
    exchange_day: date | None = None
    """Data kursu EBC, gdy stawki przeliczono z innej waluty; ``None`` – bez przeliczania."""
    provider: str
    """Kto policzył koszt: "core" albo moduł, który dostarcza dokładniejsze wyliczenie."""
    estimated: Literal[True] = True


class _Rates(BaseModel):
    profile: CostProfile
    source: Literal["vehicle", "company", "mixed"]
    currencies: list[str]
    exchange_day: date | None


def display_currency(chosen: str | None, vehicle, company) -> str:
    """Waluta kosztów: wybrana przez użytkownika, firmy pojazdu, stawek pojazdu albo euro."""
    if chosen:
        return chosen
    if company is not None:
        return company.cost_currency
    return getattr(vehicle, "cost_currency", None) or BASE


def countries(edges: list | None) -> list[CountryDistance]:
    """Kilometry trasy w każdym kraju, z podziałem na klasy dróg i drogi płatne.

    ``edges`` – odcinki ``route_analysis.RouteEdge`` (bez importu: ten moduł importują pojazdy).
    """
    found: dict[str, dict[tuple[str, bool], float]] = {}
    for edge in edges or []:
        roads = found.setdefault(edge.country, {})
        key = (edge.road_class, edge.toll)
        roads[key] = roads.get(key, 0.0) + edge.length_km
    return [
        CountryDistance(
            country=country,
            km=round(sum(roads.values()), 3),
            roads=[RoadKm(road_class=k[0], toll=k[1], km=round(v, 3)) for k, v in roads.items()],
        )
        for country, roads in found.items()
    ]


def rates_for(
    vehicle, company, fx: Rates, currency: str, prices: Prices | None = None
) -> _Rates | None:
    """Stawki pojazdu (``VehicleProfile``), brakujące z firmy, przeliczone na ``currency``,
    oraz ceny paliwa i AdBlue pojazdu (gdy podano spalanie).

    ``None``, gdy nikt nie podał stawek ani spalania (ceny ON w krajach dokłada ``prices``).
    Gdy brak kursu, koszt zostaje w walucie stawek (o ile wszystkie są w jednej), zamiast
    go zgadywać.
    """
    found: dict[str, tuple[float, str]] = {}
    sources = set()
    for field in ("cost_per_km", "cost_per_hour"):
        for source, holder in (("vehicle", vehicle), ("company", company)):
            value = getattr(holder, field, None)
            if value is not None:
                found[field] = (value, holder.cost_currency)
                sources.add(source)
                break
    consumption = getattr(vehicle, "consumption_loaded", None) or getattr(
        vehicle, "consumption_empty", None
    )
    if consumption:
        for field in ("fuel_price", "adblue_price"):
            if (value := getattr(vehicle, field)) is not None:
                found[field] = (value, vehicle.cost_currency)
        sources.add("vehicle")
    if not found and not consumption:
        return None
    currencies = sorted({c for _, c in found.values()})
    targets = [currency] + (currencies if len(currencies) == 1 else [])
    for target in targets:
        converted = {f: fx.convert(v, c, target) for f, (v, c) in found.items()}
        if None in converted.values():
            continue
        diesel = {}
        if prices is not None and getattr(vehicle, "fuel_type", None) in (None, "diesel"):
            for country, eur in prices.diesel_eur.items():
                if (price := fx.convert(eur, BASE, target)) is not None:
                    diesel[country] = price
        return _Rates(
            profile=CostProfile(
                per_km=converted.get("cost_per_km", 0.0),
                per_hour=converted.get("cost_per_hour", 0.0),
                currency=target,
                consumption=consumption,
                fuel_price=converted.get("fuel_price"),
                adblue_percent=getattr(vehicle, "adblue_percent", None),
                adblue_price=converted.get("adblue_price"),
                vehicle=_cost_vehicle(vehicle),
                diesel_prices=diesel,
                diesel_prices_day=prices.day if diesel else None,
                per_eur={**fx.per_eur, BASE: 1.0},
            ),
            source=sources.pop() if len(sources) == 1 else "mixed",
            currencies=currencies,
            exchange_day=fx.day if currencies != [target] else None,
        )
    return None


def _cost_vehicle(vehicle) -> CostVehicle | None:
    if not hasattr(vehicle, "axle_count"):
        return None
    return CostVehicle(
        kind=str(vehicle.kind),
        gvw_t=vehicle.gvw_t or vehicle.weight_t,
        axle_count=vehicle.axle_count,
        emission_class=vehicle.emission_class,
        co2_class=vehicle.co2_class,
        fuel_type=vehicle.fuel_type,
    )


def _rounded(part: CostPart) -> CostPart:
    local = None if part.local_amount is None else round(part.local_amount, 2)
    return part.model_copy(update={"amount": round(part.amount, 2), "local_amount": local})


def estimate(
    extensions: ExtensionRegistry,
    rates: _Rates | None,
    distance_km,
    duration_min,
    route_countries: list[CountryDistance] | None = None,
    allowed: Callable[[str], bool] | None = None,
) -> RouteCost | None:
    """Koszt trasy przez gniazdo ``COST_PROVIDER``; ``allowed`` – czy konto może użyć modułu
    o danym id (moduł kosztów liczy tylko dla kont, które go wykupiły; inaczej – rdzeń)."""
    if rates is None:
        return None
    profile = rates.profile.model_copy(update={"countries": route_countries or []})
    provider, owner = extensions.get_allowed(
        COST_PROVIDER, lambda module: module == "core" or allowed is None or allowed(module)
    )
    amount = provider.estimate(distance_km, duration_min / 60, profile)
    parts = []
    if isinstance(provider, CostBreakdown):
        parts = provider.parts(distance_km, duration_min / 60, profile)
        fuel = sum(p.amount for p in parts if p.kind == "fuel")
        adblue = sum(p.amount for p in parts if p.kind == "adblue")
        counted = any(p.kind == "fuel" for p in parts)
    else:
        fuel, adblue = fuel_costs(distance_km, profile)
        counted = bool(profile.consumption and profile.fuel_price)
    if amount <= 0 and not parts:
        return None  # samo spalanie bez żadnej ceny – nie ma z czego liczyć
    return RouteCost(
        amount=round(amount, 2),
        currency=profile.currency,
        per_km=round(profile.per_km, 4),
        per_hour=round(profile.per_hour, 2),
        fuel=round(fuel, 2) if counted else None,
        adblue=round(adblue, 2) if adblue else None,
        consumption=profile.consumption if counted else None,
        parts=[_rounded(p) for p in parts],
        fuel_prices_day=profile.diesel_prices_day if counted else None,
        source=rates.source,
        rates_currencies=rates.currencies,
        exchange_day=rates.exchange_day,
        provider=owner,
    )
