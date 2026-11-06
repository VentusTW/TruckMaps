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
    DASHBOARD_FEED,
    DRIVER_CHECK,
    CostBreakdown,
    CostPart,
    CostProfile,
    CostProvider,
    CostVehicle,
    CountryDistance,
    DashboardAlert,
    DashboardFeed,
    DashboardKpi,
    DashboardPart,
    DriverCheck,
    ExtensionPoint,
    RoadKm,
    fuel_costs,
)
from truckmaps.sdk.fleet import (
    SERVICE_ROLES,
    CargoInfo,
    CompanyInfo,
    DrivingInfo,
    Fleet,
    MemberInfo,
    Storage,
    TripInfo,
    VehicleInfo,
)
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
    "DASHBOARD_FEED",
    "DashboardAlert",
    "DashboardFeed",
    "DashboardKpi",
    "DashboardPart",
    "DRIVER_CHECK",
    "DriverCheck",
    "DrivingInfo",
    "Event",
    "EventBus",
    "ExtensionPoint",
    "Extensions",
    "Fleet",
    "CompanyInfo",
    "MemberInfo",
    "Module",
    "Principal",
    "RoadKm",
    "SERVICE_ROLES",
    "Storage",
    "TripInfo",
    "VehicleInfo",
    "fuel_costs",
    "i18n",
]
