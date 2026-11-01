"""Domyślne implementacje gniazd – działają, gdy żaden moduł nie dostarcza lepszej."""

from truckmaps.core.extensions import ExtensionRegistry
from truckmaps.sdk import COST_PROVIDER, CostProfile, fuel_costs


class FlatCostProvider:
    """Koszt = km × stawka za km + godziny × stawka za godzinę + paliwo i AdBlue
    ze spalania i własnych cen z profilu pojazdu."""

    def estimate(self, distance_km: float, duration_h: float, profile: CostProfile) -> float:
        fuel, adblue = fuel_costs(distance_km, profile)
        return distance_km * profile.per_km + duration_h * profile.per_hour + fuel + adblue


def register_defaults(registry: ExtensionRegistry) -> None:
    registry.set_default(COST_PROVIDER, FlatCostProvider())
