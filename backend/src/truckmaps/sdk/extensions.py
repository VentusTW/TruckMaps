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
    """Koszty eksploatacji pojazdu podane przez przewoźnika."""

    eur_per_km: float = 1.0
    eur_per_hour: float = 0.0


@runtime_checkable
class CostProvider(Protocol):
    def estimate(self, distance_km: float, duration_h: float, profile: CostProfile) -> float:
        """Zwraca koszt przejazdu w EUR."""
        ...


COST_PROVIDER = ExtensionPoint("cost_provider", CostProvider)
