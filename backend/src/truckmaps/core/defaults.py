"""Domyślne implementacje gniazd – działają, gdy żaden moduł nie dostarcza lepszej."""

from truckmaps.core.extensions import ExtensionRegistry
from truckmaps.sdk import COST_PROVIDER, CostProfile


class FlatCostProvider:
    """Koszt = km × stawka za km + godziny × stawka za godzinę."""

    def estimate(self, distance_km: float, duration_h: float, profile: CostProfile) -> float:
        return distance_km * profile.eur_per_km + duration_h * profile.eur_per_hour


def register_defaults(registry: ExtensionRegistry) -> None:
    registry.set_default(COST_PROVIDER, FlatCostProvider())
