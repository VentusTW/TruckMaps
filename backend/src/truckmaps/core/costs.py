"""Profile kosztów: stawki za km i za godzinę pojazdu albo firmy i szacunkowy koszt trasy.

Stawka pojazdu ma pierwszeństwo, brakującą bierzemy z firmy. Każda stawka jest w walucie
swojego właściciela (pojazdu albo firmy); koszt pokazujemy w walucie wybranej przez
użytkownika, przeliczając po kursie EBC. Sam koszt liczy gniazdo ``COST_PROVIDER`` –
w rdzeniu prosto (km × stawka/km + h × stawka/h); moduł Opłaty drogowe i koszty podmieni je
na dokładniejsze (paliwo, myto per kraj).
"""

from datetime import date
from typing import Literal

from pydantic import BaseModel, Field

from truckmaps.core.currency import BASE, Currency, Rates
from truckmaps.core.extensions import ExtensionRegistry
from truckmaps.sdk import COST_PROVIDER, CostProfile

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


def rates_for(vehicle, company, fx: Rates, currency: str) -> _Rates | None:
    """Stawki pojazdu (``VehicleProfile``), brakujące z firmy, przeliczone na ``currency``.

    ``None``, gdy nikt nie podał stawek. Gdy brak kursu, koszt zostaje w walucie stawek
    (o ile wszystkie są w jednej), zamiast go zgadywać.
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
    if not found:
        return None
    currencies = sorted({c for _, c in found.values()})
    targets = [currency] + (currencies if len(currencies) == 1 else [])
    for target in targets:
        converted = {f: fx.convert(v, c, target) for f, (v, c) in found.items()}
        if None in converted.values():
            continue
        return _Rates(
            profile=CostProfile(
                per_km=converted.get("cost_per_km", 0.0),
                per_hour=converted.get("cost_per_hour", 0.0),
                currency=target,
            ),
            source=sources.pop() if len(sources) == 1 else "mixed",
            currencies=currencies,
            exchange_day=fx.day if currencies != [target] else None,
        )
    return None


def estimate(
    extensions: ExtensionRegistry, rates: _Rates | None, distance_km, duration_min
) -> RouteCost | None:
    if rates is None:
        return None
    profile = rates.profile
    amount = extensions.get(COST_PROVIDER).estimate(distance_km, duration_min / 60, profile)
    return RouteCost(
        amount=round(amount, 2),
        currency=profile.currency,
        per_km=round(profile.per_km, 4),
        per_hour=round(profile.per_hour, 2),
        source=rates.source,
        rates_currencies=rates.currencies,
        exchange_day=rates.exchange_day,
        provider=extensions.owner(COST_PROVIDER),
    )
