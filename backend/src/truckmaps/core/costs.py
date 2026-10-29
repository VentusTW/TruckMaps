"""Profile kosztów: stawki €/km i €/h pojazdu albo firmy i szacunkowy koszt trasy.

Stawka pojazdu ma pierwszeństwo, brakującą bierzemy z firmy. Sam koszt liczy gniazdo
``COST_PROVIDER`` – w rdzeniu prosto (km × €/km + h × €/h); moduł Opłaty drogowe
i koszty podmieni je na dokładniejsze (paliwo, myto per kraj).
"""

from typing import Literal

from pydantic import BaseModel, Field

from truckmaps.core.extensions import ExtensionRegistry
from truckmaps.sdk import COST_PROVIDER, CostProfile

EurPerKm = Field(
    default=None, ge=0, le=20, description="Koszt eksploatacji za kilometr [EUR]", examples=[1.1]
)
EurPerHour = Field(
    default=None, ge=0, le=500, description="Koszt za godzinę jazdy, np. kierowca [EUR]"
)


class CostRates(BaseModel):
    cost_eur_per_km: float | None = EurPerKm
    cost_eur_per_hour: float | None = EurPerHour


class RouteCost(BaseModel):
    """Szacunkowy koszt przejazdu – zawsze pokazywany jako „≈”, nigdy jako kwota pewna."""

    eur: float
    eur_per_km: float
    eur_per_hour: float
    source: Literal["vehicle", "company", "mixed"]
    """Skąd stawki: z pojazdu, z firmy albo częściowo z obu."""
    provider: str
    """Kto policzył koszt: "core" albo moduł, który dostarcza dokładniejsze wyliczenie."""
    estimated: Literal[True] = True


def rates_for(vehicle, company) -> tuple[CostProfile, str] | None:
    """Stawki pojazdu (``VehicleProfile``), brakujące z firmy; ``None``, gdy nikt ich nie podał."""
    rates, sources = {}, set()
    for field in ("cost_eur_per_km", "cost_eur_per_hour"):
        for source, holder in (("vehicle", vehicle), ("company", company)):
            value = getattr(holder, field, None)
            if value is not None:
                rates[field] = value
                sources.add(source)
                break
    if not rates:
        return None
    profile = CostProfile(
        eur_per_km=rates.get("cost_eur_per_km", 0.0),
        eur_per_hour=rates.get("cost_eur_per_hour", 0.0),
    )
    return profile, sources.pop() if len(sources) == 1 else "mixed"


def estimate(
    extensions: ExtensionRegistry, rates: tuple[CostProfile, str] | None, distance_km, duration_min
) -> RouteCost | None:
    if rates is None:
        return None
    profile, source = rates
    eur = extensions.get(COST_PROVIDER).estimate(distance_km, duration_min / 60, profile)
    return RouteCost(
        eur=round(eur, 2),
        eur_per_km=profile.eur_per_km,
        eur_per_hour=profile.eur_per_hour,
        source=source,
        provider=extensions.owner(COST_PROVIDER),
    )
