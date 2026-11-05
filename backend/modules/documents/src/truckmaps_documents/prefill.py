"""Autouzupełnianie pól dokumentu z danych systemu.

Każda wartość ma źródło (``company``, ``profile``, ``template``, ``vehicle``, ``driver``,
``route``, ``cargo``, ``trips``, ``auto``) – aplikacja oznacza pola do sprawdzenia.
Dane z planera (trasa) i z Planu załadunku (ładunek) przekazuje aplikacja w żądaniu.
"""

from dataclasses import dataclass, field, replace
from datetime import date, datetime
from typing import Literal

from pydantic import BaseModel, Field

from truckmaps.sdk import CompanyInfo, DrivingInfo, TripInfo
from truckmaps.sdk.i18n import t
from truckmaps_documents.catalog import Field as DocField
from truckmaps_documents.catalog import Kind


class Stop(BaseModel):
    label: str = Field(max_length=300)
    """Adres albo nazwa miejsca."""
    country: str | None = Field(default=None, max_length=2)
    at: datetime | None = None
    """Planowany czas (ETA)."""
    type: Literal["loading", "unloading", "via"] | None = None
    reference: str = Field(default="", max_length=100)


class RouteIn(BaseModel):
    stops: list[Stop] = Field(default_factory=list, max_length=30)
    distance_km: float | None = Field(default=None, ge=0)
    duration_min: float | None = Field(default=None, ge=0)
    cost_amount: float | None = Field(default=None, ge=0)
    cost_currency: str | None = Field(default=None, max_length=3)


class CargoItem(BaseModel):
    """Pozycja jak w Planie załadunku: sztuki, rodzaj, masa jednej sztuki."""

    kind: str = Field(default="euro", max_length=20)
    count: int = Field(ge=1, le=1000)
    weight_kg: float = Field(ge=0, le=40_000)
    label: str = Field(default="", max_length=100)


class CargoIn(BaseModel):
    items: list[CargoItem] = Field(default_factory=list, max_length=50)
    ldm: float | None = Field(default=None, ge=0)
    dangerous_goods: str = Field(default="", max_length=500)


class Profile(BaseModel):
    """Dane firmy do dokumentów (brak ich w rdzeniu)."""

    legal_name: str = Field(default="", max_length=300)
    address: str = Field(default="", max_length=300)
    postal_code: str = Field(default="", max_length=20)
    city: str = Field(default="", max_length=100)
    country: str = Field(default="", max_length=2)
    vat_id: str = Field(default="", max_length=30)
    regon: str = Field(default="", max_length=20)
    krs: str = Field(default="", max_length=20)
    eori: str = Field(default="", max_length=20)
    licence_number: str = Field(default="", max_length=60)
    ocp_policy: str = Field(default="", max_length=100)
    ocp_insurer: str = Field(default="", max_length=200)
    ocp_sum: str = Field(default="", max_length=60)
    bank_account: str = Field(default="", max_length=60)
    contact_person: str = Field(default="", max_length=200)
    phone: str = Field(default="", max_length=40)
    email: str = Field(default="", max_length=200)
    issue_place: str = Field(default="", max_length=100)
    """Miejscowość wystawiania dokumentów; brak – miejscowość z adresu."""


class ExtraField(BaseModel):
    """Pole dodane przez firmę do wzoru (klucz z przedrostkiem ``x_``)."""

    key: str = Field(default="", max_length=40)
    label: str = Field(min_length=1, max_length=120)
    type: Literal["text", "multiline", "number", "date"] = "text"
    width: Literal[0.25, 0.5, 1.0] = 1.0


class Template(BaseModel):
    """Szablon firmy dla rodzaju dokumentu."""

    defaults: dict[str, str] = Field(default_factory=dict)
    hidden: list[str] = Field(default_factory=list)
    labels: dict[str, str] = Field(default_factory=dict)
    """Zmienione etykiety pól wzoru."""
    extra_fields: list[ExtraField] = Field(default_factory=list, max_length=30)
    terms: str = Field(default="", max_length=10_000)
    """Warunki / klauzule na końcu dokumentu."""


def fields_for(kind: Kind, template: Template) -> list[DocField]:
    """Pola dokumentu wg szablonu firmy: bez ukrytych, ze zmienionymi etykietami, z polami
    dodanymi przez firmę na końcu."""
    fields = [
        replace(f, label=template.labels.get(f.key, ""))
        for f in kind.fields
        if f.key not in template.hidden
    ]
    fields += [
        DocField(x.key, x.type, x.width, label=x.label)
        for x in template.extra_fields
        if x.key not in template.hidden
    ]
    return fields


@dataclass
class Sources:
    company: CompanyInfo | None = None
    profile: Profile = field(default_factory=Profile)
    template: Template = field(default_factory=Template)
    vehicle: DrivingInfo | None = None
    driver_name: str = ""
    driver_phone: str = ""
    route: RouteIn | None = None
    cargo: CargoIn | None = None
    trips: list[TripInfo] = field(default_factory=list)
    today: date = field(default_factory=date.today)
    period: tuple[date, date] | None = None


@dataclass
class Prefill:
    data: dict[str, object] = field(default_factory=dict)
    sources: dict[str, str] = field(default_factory=dict)
    warnings: list[str] = field(default_factory=list)

    def set(self, key: str, value: object, source: str) -> None:
        if value in (None, "", []):
            return
        self.data[key] = value
        self.sources[key] = source


def company_block(company: CompanyInfo | None, profile: Profile) -> str:
    """Nazwa, adres i numery firmy w kilku wierszach."""
    name = profile.legal_name or (company.name if company else "")
    city = " ".join(p for p in (profile.postal_code, profile.city) if p)
    place = ", ".join(p for p in (city, profile.country) if p)
    tax = profile.vat_id or (company.tax_id if company else None)
    lines = [name, profile.address, place]
    if tax:
        lines.append(t("documents.text.tax_id", value=tax))
    return "\n".join(line for line in lines if line)


def _place(stop: Stop) -> str:
    return f"{stop.label} ({stop.country})" if stop.country else stop.label


def _number(value: float) -> float | int:
    return int(value) if float(value).is_integer() else round(value, 2)


def _goods(cargo: CargoIn, columns: str) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for item in cargo.items:
        packing = t(f"documents.packing.{item.kind}") if item.kind else ""
        row: dict[str, object] = {
            "marks": item.label,
            "packages": item.count,
            "packing": packing,
            "nature": item.label,
            "gross_kg": _number(item.count * item.weight_kg),
        }
        rows.append({k: v for k, v in row.items() if k in columns})
    return rows


def _vehicle(result: Prefill, vehicle: DrivingInfo | None) -> None:
    if vehicle is None:
        return
    result.set("tractor_plate", vehicle.plate or vehicle.name, "vehicle")
    result.set("trailer_plate", vehicle.trailer_plate, "vehicle")


def _issued(result: Prefill, src: Sources) -> None:
    profile = src.profile
    result.set("issued_place", profile.issue_place or profile.city, "profile")
    result.set("issued_date", src.today.isoformat(), "auto")


def _cmr(result: Prefill, src: Sources) -> None:
    carrier = company_block(src.company, src.profile)
    if src.profile.licence_number:
        carrier += "\n" + t("documents.text.licence", value=src.profile.licence_number)
    result.set("carrier", carrier, "company")
    if src.route and src.route.stops:
        first, last = src.route.stops[0], src.route.stops[-1]
        when = (first.at.date() if first.at else src.today).isoformat()
        result.set("loading_place_date", f"{_place(first)}\n{when}", "route")
        if len(src.route.stops) > 1:
            result.set("delivery_place", _place(last), "route")
    if src.cargo:
        result.set("goods", _goods(src.cargo, "marks packages packing nature gross_kg"), "cargo")
        result.set("dangerous_goods", src.cargo.dangerous_goods, "cargo")
    if src.route and src.route.cost_amount is not None:
        currency = src.route.cost_currency or ""
        result.set("charges", f"{src.route.cost_amount:.2f} {currency}".strip(), "route")
    _vehicle(result, src.vehicle)
    _issued(result, src)


def _order(result: Prefill, src: Sources) -> None:
    block = company_block(src.company, src.profile)
    if src.company and src.company.kind == "forwarder":
        result.set("principal", block, "company")
    else:
        if src.profile.licence_number:
            block += "\n" + t("documents.text.licence", value=src.profile.licence_number)
        result.set("carrier", block, "company")
    _vehicle(result, src.vehicle)
    if src.vehicle:
        kind = src.vehicle.trailer_kind or src.vehicle.kind
        result.set("vehicle_type", t(f"documents.vehicle_kind.{kind}"), "vehicle")
    result.set("driver_name", src.driver_name, "driver")
    result.set("driver_phone", src.driver_phone, "driver")
    route = src.route
    if route:
        stops = []
        for i, stop in enumerate(route.stops):
            kind = stop.type or (
                "loading" if i == 0 else "unloading" if i == len(route.stops) - 1 else "via"
            )
            stops.append(
                {
                    "stop_type": t(f"documents.stop.{kind}"),
                    "place": _place(stop),
                    "date_time": stop.at.strftime("%Y-%m-%d %H:%M") if stop.at else "",
                    "reference": stop.reference,
                }
            )
        result.set("stops", stops, "route")
        if route.distance_km is not None:
            result.set("distance_km", round(route.distance_km), "route")
        if route.duration_min is not None:
            result.set("duration_h", round(route.duration_min / 60, 1), "route")
        if route.cost_amount is not None:
            freight = f"{route.cost_amount:.2f} {route.cost_currency or ''}".strip()
            result.set("freight", freight, "route")
    if src.cargo:
        rows = _goods(src.cargo, "nature packages packing gross_kg")
        if rows and src.cargo.ldm is not None:
            rows[0]["ldm"] = src.cargo.ldm
        result.set("goods", rows, "cargo")
        result.set("dangerous_goods", src.cargo.dangerous_goods, "cargo")
    profile = src.profile
    if profile.ocp_policy:
        insurance = t(
            "documents.text.ocp",
            policy=profile.ocp_policy,
            insurer=profile.ocp_insurer or "–",
            sum=profile.ocp_sum or "–",
        )
        result.set("insurance", insurance, "profile")
    contact = ", ".join(p for p in (profile.contact_person, profile.phone, profile.email) if p)
    result.set("contact_person", contact, "profile")
    result.set("issued_date", src.today.isoformat(), "auto")


def _road_card(result: Prefill, src: Sources) -> None:
    result.set("company", company_block(src.company, src.profile), "company")
    vehicle = src.vehicle
    if vehicle:
        result.set("vehicle", vehicle.name, "vehicle")
    _vehicle(result, vehicle)
    result.set("driver_name", src.driver_name, "driver")
    start, end = src.period or (src.today, src.today)
    result.set("period_from", start.isoformat(), "auto")
    result.set("period_to", end.isoformat(), "auto")
    trips = sorted(
        (trip for trip in src.trips if start <= trip.started_at.date() <= end),
        key=lambda trip: trip.started_at,
    )
    rows = []
    for trip in trips:
        loaded = (
            "" if trip.loaded is None else t(f"documents.text.loaded_{str(trip.loaded).lower()}")
        )
        rows.append(
            {
                "date": trip.started_at.date().isoformat(),
                "departure": trip.started_at.strftime("%H:%M"),
                "arrival": trip.ended_at.strftime("%H:%M"),
                "route": "",
                "km": round(trip.distance_km),
                "loaded": loaded,
            }
        )
    result.set("trips", rows, "trips")
    total = round(sum(trip.distance_km for trip in trips))
    if trips:
        result.set("total_km", total, "trips")
    # Stan licznika – ostatni znany; początek okresu = koniec − przejechane km (podpowiedź).
    if vehicle and vehicle.odometer_km is not None and end >= src.today:
        result.set("odometer_end", vehicle.odometer_km, "vehicle")
        result.set("odometer_start", max(0, vehicle.odometer_km - total), "trips")


FILLERS = {"cmr": _cmr, "transport_order": _order, "road_card": _road_card}


def prefill(kind: str, src: Sources) -> Prefill:
    result = Prefill()
    FILLERS[kind](result, src)
    # Wartości domyślne z szablonu firmy – tam, gdzie system nic nie podpowiedział.
    for key, value in src.template.defaults.items():
        if key not in result.data:
            result.set(key, value, "template")
    if src.template.terms and "terms" not in result.data and kind == "transport_order":
        result.set("terms", src.template.terms, "template")
    if src.vehicle and src.vehicle.hazmat and "dangerous_goods" not in result.data:
        result.warnings.append(t("documents.warn.adr"))
    if src.company and not src.profile.address:
        result.warnings.append(t("documents.warn.no_profile"))
    return result
