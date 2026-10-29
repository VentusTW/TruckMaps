from dataclasses import dataclass
from typing import Protocol, runtime_checkable

from pydantic import BaseModel


@dataclass(frozen=True)
class ExtensionPoint[T]:
    """Gniazdo, w które moduł może podłączyć własną implementację.

    Rdzeń zawsze ma implementację domyślną, więc brak modułu niczego nie psuje.
    """

    key: str
    protocol: type[T]


class CostProfile(BaseModel):
    """Koszty eksploatacji pojazdu podane przez przewoźnika, w walucie ``currency``."""

    per_km: float = 1.0
    per_hour: float = 0.0
    currency: str = "EUR"
    """Kod ISO 4217 – w tej walucie są stawki i wynik ``CostProvider.estimate``."""


@runtime_checkable
class CostProvider(Protocol):
    def estimate(self, distance_km: float, duration_h: float, profile: CostProfile) -> float:
        """Zwraca koszt przejazdu w walucie profilu (``profile.currency``)."""
        ...


COST_PROVIDER = ExtensionPoint("cost_provider", CostProvider)
