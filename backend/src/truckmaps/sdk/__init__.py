"""Publiczne API TruckMaps dla modułów.

Moduły importują wyłącznie z tego pakietu. Wszystko w ``truckmaps.core`` jest
wewnętrzne – pilnuje tego import-linter (plik ``.importlinter``).
"""

from truckmaps.sdk import i18n
from truckmaps.sdk.auth import Auth, Principal
from truckmaps.sdk.context import ApiRegistry, CoreContext, EventBus, Extensions
from truckmaps.sdk.events import CoreReady, Event
from truckmaps.sdk.extensions import (
    COST_PROVIDER,
    CostBreakdown,
    CostPart,
    CostProfile,
    CostProvider,
    CostVehicle,
    CountryDistance,
    ExtensionPoint,
    RoadKm,
    fuel_costs,
)
from truckmaps.sdk.fleet import SERVICE_ROLES, CargoInfo, Fleet, Storage, VehicleInfo
from truckmaps.sdk.module import Module

__all__ = [
    "COST_PROVIDER",
    "ApiRegistry",
    "Auth",
    "CargoInfo",
    "CoreContext",
    "CoreReady",
    "CostBreakdown",
    "CostPart",
    "CostProfile",
    "CostProvider",
    "CostVehicle",
    "CountryDistance",
    "Event",
    "EventBus",
    "ExtensionPoint",
    "Extensions",
    "Fleet",
    "Module",
    "Principal",
    "RoadKm",
    "SERVICE_ROLES",
    "Storage",
    "VehicleInfo",
    "fuel_costs",
    "i18n",
]
