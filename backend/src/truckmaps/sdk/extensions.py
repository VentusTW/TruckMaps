from dataclasses import dataclass
from datetime import date
from typing import Literal, Protocol, runtime_checkable

from pydantic import BaseModel
from sqlalchemy.orm import Session

from truckmaps.sdk.auth import Principal


@dataclass(frozen=True)
class ExtensionPoint[T]:
    """Gniazdo, w które moduł może podłączyć własną implementację.

    Rdzeń zawsze ma implementację domyślną, więc brak modułu niczego nie psuje.
    """

    key: str
    protocol: type[T]


class RoadKm(BaseModel):
    road_class: str
    """Klasa drogi Valhalli: motorway, trunk, primary, secondary…"""
    toll: bool
    """Droga płatna według OSM (``toll=yes``)."""
    km: float


class CountryDistance(BaseModel):
    """Część trasy w jednym kraju – do cen paliwa i myta per kraj."""

    country: str
    """Kod ISO 3166-1 (np. "DE"); pusty, gdy kraju nie rozpoznano."""
    km: float
    roads: list[RoadKm] = []


class CostVehicle(BaseModel):
    """Cechy pojazdu, od których zależy myto."""

    kind: str
    gvw_t: float
    axle_count: int
    emission_class: str | None = None
    co2_class: int | None = None
    fuel_type: str | None = None


class CostPart(BaseModel):
    """Część szacunkowego kosztu trasy, w walucie profilu."""

    kind: Literal["distance", "time", "fuel", "adblue", "toll"]
    amount: float
    country: str = ""
    km: float | None = None
    """Paliwo: km w kraju; myto: km płatnych dróg."""
    unknown: bool = False
    """Myto: są płatne drogi, ale stawki dla tego pojazdu nie znamy (kwota 0)."""
    source: str | None = None
    """Myto: cennik operatora (adres), z którego wzięto stawkę."""
    local_amount: float | None = None
    local_currency: str | None = None
    """Kwota w walucie kraju (np. myto w PLN przy koszcie w EUR) – do pokazania obok;
    brak, gdy waluta kraju jest walutą profilu albo nie ma kursu."""


class CostProfile(BaseModel):
    """Koszty eksploatacji pojazdu podane przez przewoźnika, w walucie ``currency``."""

    per_km: float = 1.0
    per_hour: float = 0.0
    currency: str = "EUR"
    """Kod ISO 4217 – w tej walucie są stawki i wynik ``CostProvider.estimate``."""
    consumption: float | None = None
    """Spalanie na 100 km (l, kg albo kWh) – z ładunkiem, a gdy go brak, bez ładunku."""
    fuel_price: float | None = None
    """Cena paliwa za jednostkę, w walucie ``currency``."""
    adblue_percent: float | None = None
    """AdBlue jako % spalania (tylko ON)."""
    adblue_price: float | None = None
    """Cena AdBlue za litr, w walucie ``currency``."""
    vehicle: CostVehicle | None = None
    countries: list[CountryDistance] = []
    """Trasa po krajach; pusta, gdy silnik tras nie podał odcinków."""
    diesel_prices: dict[str, float] = {}
    """Kraj → cena ON za litr w walucie ``currency`` (Weekly Oil Bulletin KE)."""
    diesel_prices_day: date | None = None
    per_eur: dict[str, float] = {}
    """Kursy EBC (jednostki waluty za 1 euro) – do przeliczania cenników myta."""


def fuel_costs(distance_km: float, profile: CostProfile) -> tuple[float, float]:
    """Paliwo i AdBlue na trasie (w walucie profilu); 0, gdy brak spalania albo ceny.

    Przy wyliczonym paliwie stawka za km oznacza pozostałe koszty (opony, amortyzacja…).
    """
    if not profile.consumption or not profile.fuel_price:
        return 0.0, 0.0
    used = distance_km * profile.consumption / 100
    adblue = 0.0
    if profile.adblue_percent and profile.adblue_price:
        adblue = used * profile.adblue_percent / 100 * profile.adblue_price
    return used * profile.fuel_price, adblue


@runtime_checkable
class CostProvider(Protocol):
    def estimate(self, distance_km: float, duration_h: float, profile: CostProfile) -> float:
        """Zwraca koszt przejazdu w walucie profilu (``profile.currency``)."""
        ...


@runtime_checkable
class CostBreakdown(Protocol):
    """Dostawca kosztu, który podaje też części (paliwo i myto per kraj); opcjonalne."""

    def parts(self, distance_km: float, duration_h: float, profile: CostProfile) -> list[CostPart]:
        """Części kosztu, w walucie profilu; ich suma to ``estimate``."""
        ...


COST_PROVIDER = ExtensionPoint("cost_provider", CostProvider)


@runtime_checkable
class DriverCheck(Protocol):
    def warnings(self, db: Session, user: Principal, vehicle_id: str) -> list[str]:
        """Ostrzeżenia o kierowcy przed jazdą tym pojazdem (np. brak kategorii prawa jazdy,
        przeterminowane badania) – w języku użytkownika; pusta lista – bez uwag."""
        ...


class NoDriverCheck:
    """Rdzeń bez modułu kierowców nie zna uprawnień kierowcy."""

    def warnings(self, db: Session, user: Principal, vehicle_id: str) -> list[str]:
        return []


DRIVER_CHECK = ExtensionPoint("driver_check", DriverCheck)


class DashboardKpi(BaseModel):
    """Wskaźnik na pulpicie operacyjnym; etykietę dobiera aplikacja po ``key`` (teksty w .arb)."""

    key: str
    """Np. "drivers.active", "service.open" – prefiks to moduł."""
    value: float
    total: float | None = None
    """Mianownik (np. 12 z 15 pojazdów); brak – sama liczba."""
    unit: str = ""
    """"%", "km" albo kod waluty."""
    tone: Literal["ok", "warning", "error", "info"] = "info"
    order: int = 100


class DashboardAlert(BaseModel):
    """Sprawa wymagająca uwagi dyspozytora; tekst składa aplikacja z ``kind`` i ``data``."""

    id: str
    """Stały identyfikator sprawy (np. "drivers:due:<id>:medical_until:2026-11-20") – po nim
    pulpit pamięta, że sprawę obsłużono; nowa sprawa (inny termin) dostaje nowy id."""
    kind: str
    severity: Literal["critical", "warning", "info"]
    data: dict = {}
    vehicle_id: str | None = None
    driver_subject: str | None = None
    """Konto kierowcy – do akcji „wyślij wiadomość”."""
    due: date | None = None
    """Termin sprawy – sortowanie w obrębie tej samej wagi."""


class DashboardPart(BaseModel):
    kpis: list[DashboardKpi] = []
    alerts: list[DashboardAlert] = []


@runtime_checkable
class DashboardFeed(Protocol):
    """Część pulpitu operacyjnego dostarczana przez moduł (może ich być wiele naraz)."""

    def collect(self, db: Session, company_id: str, today: date) -> DashboardPart:
        """Wskaźniki i sprawy firmy ``company_id`` na dzień ``today``."""
        ...


DASHBOARD_FEED = ExtensionPoint("dashboard_feed", DashboardFeed)
