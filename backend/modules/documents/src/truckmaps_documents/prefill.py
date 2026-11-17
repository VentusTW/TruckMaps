"""Autouzupełnianie pól dokumentu z danych systemu.

Każda wartość ma źródło (``company``, ``profile``, ``template``, ``vehicle``, ``driver``,
``route``, ``cargo``, ``trips``, ``auto``) – aplikacja oznacza pola do sprawdzenia.
Dane z planera (trasa) i z Planu załadunku (ładunek) przekazuje aplikacja w żądaniu.
"""

from dataclasses import dataclass, field, replace
from datetime import date, datetime, timedelta
from typing import Literal

from pydantic import BaseModel, Field

from truckmaps.sdk import CompanyInfo, DriverRecord, DrivingInfo, TripInfo
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
    driver: DriverRecord | None = None
    """Kierowca z kartoteki (moduł Kierowcy przez gniazdo ``DRIVER_DIRECTORY``)."""


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


def _insurance(result: Prefill, profile: Profile) -> None:
    if profile.ocp_policy:
        insurance = t(
            "documents.text.ocp",
            policy=profile.ocp_policy,
            insurer=profile.ocp_insurer or "–",
            sum=profile.ocp_sum or "–",
        )
        result.set("insurance", insurance, "profile")


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
    _insurance(result, profile)
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


def _pod(result: Prefill, src: Sources) -> None:
    result.set("carrier", company_block(src.company, src.profile), "company")
    _vehicle(result, src.vehicle)
    result.set("driver_name", src.driver_name, "driver")
    if src.route and src.route.stops:
        last = src.route.stops[-1]
        result.set("delivery_place", _place(last), "route")
        if last.at:
            result.set("arrival", last.at.strftime("%Y-%m-%d %H:%M"), "route")
    if src.cargo:
        result.set("goods", _goods(src.cargo, "nature packages packing gross_kg"), "cargo")


def _damage(result: Prefill, src: Sources) -> None:
    carrier = company_block(src.company, src.profile)
    if src.profile.licence_number:
        carrier += "\n" + t("documents.text.licence", value=src.profile.licence_number)
    result.set("carrier", carrier, "company")
    _insurance(result, src.profile)
    _vehicle(result, src.vehicle)
    result.set("driver_name", src.driver_name, "driver")
    last = src.route.stops[-1] if src.route and src.route.stops else None
    if last:
        result.set("found_place", _place(last), "route")
    if last and last.at:
        result.set("found_at", last.at.strftime("%Y-%m-%d %H:%M"), "route")
    else:
        result.set("found_at", src.today.isoformat(), "auto")
    if src.cargo:
        result.set("goods", _goods(src.cargo, "nature packages packing gross_kg"), "cargo")


def _loading(result: Prefill, src: Sources) -> None:
    carrier = company_block(src.company, src.profile)
    if src.profile.licence_number:
        carrier += "\n" + t("documents.text.licence", value=src.profile.licence_number)
    result.set("carrier", carrier, "company")
    _vehicle(result, src.vehicle)
    result.set("driver_name", src.driver_name, "driver")
    first = src.route.stops[0] if src.route and src.route.stops else None
    if first:
        result.set("loading_place", _place(first), "route")
    if first and first.at:
        result.set("loaded_at", first.at.strftime("%Y-%m-%d %H:%M"), "route")
    else:
        result.set("loaded_at", src.today.isoformat(), "auto")
    cargo = src.cargo
    if cargo:
        result.set("goods", _goods(cargo, "nature packages packing gross_kg"), "cargo")
        if cargo.items:
            total = sum(item.count * item.weight_kg for item in cargo.items)
            result.set("total_kg", _number(total), "cargo")
        if cargo.ldm is not None:
            result.set("ldm", cargo.ldm, "cargo")
        result.set("dangerous_goods", cargo.dangerous_goods, "cargo")


def posting_operation(home: str, stops: list[Stop]) -> tuple[str, list[str]] | None:
    """Rodzaj przewozu z krajów załadunku i rozładunku (dyrektywa 2020/1057 art. 1):
    kabotaż – oba w tym samym obcym kraju, cross-trade – oba poza krajem siedziby i różne,
    ``bilateral`` – przewóz z kraju siedziby albo do niego (bez delegowania).
    ``None`` – nie wiadomo (brak kraju firmy albo krajów załadunku i rozładunku)."""
    countries = [s.country.upper() for s in stops if s.country]
    if len(countries) < 2 or not home:
        return None
    first, last = countries[0], countries[-1]
    if home in (first, last):
        return "bilateral", []
    if first == last:
        return "cabotage", [first]
    return "cross_trade", [first, last]


def _posting(result: Prefill, src: Sources) -> None:
    carrier = company_block(src.company, src.profile)
    if src.profile.licence_number:
        carrier += "\n" + t("documents.text.licence", value=src.profile.licence_number)
    result.set("carrier", carrier, "company")
    profile = src.profile
    contact = "\n".join(p for p in (profile.contact_person, profile.phone, profile.email) if p)
    result.set("contact_person", contact, "profile")
    result.set("driver_name", src.driver_name, "driver")
    result.set("applicable_law", (profile.country or "").upper(), "profile")
    _vehicle(result, src.vehicle)
    start, end = src.period or (src.today, src.today)
    stops = src.route.stops if src.route else []
    source = "auto"
    if src.period is None and stops and stops[0].at:
        start = end = stops[0].at.date()
        if stops[-1].at:
            end = max(start, stops[-1].at.date())
        source = "route"
    result.set("period_from", start.isoformat(), source)
    result.set("period_to", end.isoformat(), source)
    operation = posting_operation((profile.country or "").upper(), stops)
    if operation is not None:
        kind, countries = operation
        if kind == "bilateral":
            result.warnings.append(t("documents.warn.not_posting"))
        else:
            result.set("transport_type", t(f"documents.text.{kind}"), "route")
            result.set("host_country", ", ".join(countries), "route")
    result.set("notes", t("documents.text.posting_notes"), "auto")
    _issued(result, src)


def _carrier(src: Sources) -> str:
    carrier = company_block(src.company, src.profile)
    if src.profile.licence_number:
        carrier += "\n" + t("documents.text.licence", value=src.profile.licence_number)
    return carrier


def _stamp(value: datetime) -> str:
    return value.strftime("%Y-%m-%d %H:%M")


def _ends(src: Sources) -> tuple[Stop | None, Stop | None]:
    stops = src.route.stops if src.route else []
    return (stops[0], stops[-1]) if stops else (None, None)


def _route_period(src: Sources) -> tuple[date, date, str]:
    """Okres dokumentu: z żądania, z czasów trasy albo dzisiaj (źródło podpowiedzi)."""
    if src.period:
        return src.period[0], src.period[1], "auto"
    first, last = _ends(src)
    if first and first.at:
        end = max(first.at.date(), last.at.date()) if last and last.at else first.at.date()
        return first.at.date(), end, "route"
    return src.today, src.today, "auto"


def _period_trips(src: Sources) -> list[TripInfo]:
    start, end = src.period or (src.today, src.today)
    return sorted(
        (trip for trip in src.trips if start <= trip.started_at.date() <= end),
        key=lambda trip: trip.started_at,
    )


def _consignment(result: Prefill, src: Sources) -> None:
    """Krajowy list przewozowy – pola jak w CMR (Prawo przewozowe art. 38–39)."""
    _cmr(result, src)
    for key in ("dangerous_goods",):
        result.data.pop(key, None)
        result.sources.pop(key, None)


ACTIVITY_REASONS = ("sick", "annual_leave", "rest", "exempt_vehicle", "other_work", "available")
"""Przyczyny z wzoru decyzji 2009/959/UE (pola 14–19)."""


def _driver_activity(result: Prefill, src: Sources) -> None:
    profile = src.profile
    block = company_block(src.company, src.profile)
    contact = "\n".join(p for p in (profile.phone, profile.email) if p)
    result.set("company", f"{block}\n{contact}".strip(), "company")
    result.set("signer_name", profile.contact_person, "profile")
    result.set("driver_name", src.driver_name, "driver")
    if src.driver and src.driver.hired_on:
        result.set("work_start", src.driver.hired_on.isoformat(), "driver")
    start, end = src.period or (src.today, src.today)
    result.set("period_from", f"{start.isoformat()} 00:00", "auto")
    result.set("period_to", f"{end.isoformat()} 23:59", "auto")
    reasons = [
        {"mark": "", "reason": t(f"documents.text.activity_{reason}")}
        for reason in ACTIVITY_REASONS
    ]
    result.set("reasons", reasons, "auto")
    result.set("driver_statement", t("documents.text.activity_statement"), "auto")
    _issued(result, src)


DOMESTIC_RATE = 45.0
"""Dieta krajowa [PLN] – rozporządzenie MRPiPS z 29.01.2013 (od 1.01.2023)."""

FOREIGN_RATES: dict[str, tuple[float, str]] = {
    "AT": (52, "EUR"),
    "BE": (48, "EUR"),
    "CH": (88, "CHF"),
    "CZ": (41, "EUR"),
    "DE": (49, "EUR"),
    "DK": (406, "DKK"),
    "ES": (50, "EUR"),
    "FR": (50, "EUR"),
    "GB": (35, "GBP"),
    "HU": (44, "EUR"),
    "IT": (48, "EUR"),
    "LT": (39, "EUR"),
    "NL": (50, "EUR"),
    "NO": (451, "NOK"),
    "SE": (459, "SEK"),
    "SK": (43, "EUR"),
}
"""Diety zagraniczne – załącznik do rozporządzenia MRPiPS z 29.01.2013; kraje spoza tabeli
i zmiany stawek – do wpisania w dokumencie."""


def per_diem_days(hours: float, foreign: bool, whole_trip_h: float | None = None) -> float:
    """Liczba diet za czas pobytu (rozporządzenie MRPiPS z 29.01.2013 § 8 i § 13).

    Kraj: podróż do doby – do 8 h nic, 8–12 h ½, ponad 12 h 1; dłuższa – każda doba 1,
    reszta do 8 h ½, ponad 8 h 1. Za granicą: każda doba 1, reszta do 8 h ⅓, 8–12 h ½,
    ponad 12 h 1."""
    days, rest = divmod(max(0.0, hours), 24)
    if foreign:
        part = 0 if rest == 0 else 1 / 3 if rest <= 8 else 0.5 if rest <= 12 else 1
        return round(days + part, 2)
    if (whole_trip_h if whole_trip_h is not None else hours) <= 24:
        return 0 if hours < 8 else 0.5 if hours <= 12 else 1
    return days + (0 if rest == 0 else 0.5 if rest <= 8 else 1)


def _country_runs(stops: list[Stop]) -> list[tuple[str, datetime, datetime]]:
    """Pobyty w krajach z przystanków trasy (kraj, wjazd, wyjazd) – granica w chwili
    pierwszego przystanku w następnym kraju (przybliżenie do sprawdzenia)."""
    timed = [s for s in stops if s.country and s.at]
    runs: list[list] = []
    for stop in timed:
        country = (stop.country or "").upper()
        if runs and runs[-1][0] == country:
            runs[-1][2] = stop.at
        else:
            if runs:
                runs[-1][2] = stop.at
            runs.append([country, stop.at, stop.at])
    return [(c, a, b) for c, a, b in runs if b >= a]


def _business_trip(result: Prefill, src: Sources) -> None:
    result.set("employer", company_block(src.company, src.profile), "company")
    result.set("driver_name", src.driver_name, "driver")
    result.set("purpose", t("documents.text.trip_purpose"), "auto")
    stops = src.route.stops if src.route else []
    result.set("destination", " → ".join(_place(s) for s in stops), "route")
    if src.vehicle:
        plate = src.vehicle.plate or ""
        result.set("transport", f"{src.vehicle.name} {plate}".strip(), "vehicle")
    start, end, source = _route_period(src)
    trips = _period_trips(src)
    if source == "auto" and not src.period and trips:
        start, end, source = trips[0].started_at.date(), trips[-1].ended_at.date(), "trips"
    result.set("period_from", start.isoformat(), source)
    result.set("period_to", end.isoformat(), source)
    home = (src.profile.country or "PL").upper()
    runs = _country_runs(stops)
    if runs:
        whole = (runs[-1][2] - runs[0][1]).total_seconds() / 3600
        countries, diems, totals = [], [], {}
        for country, entered, left in runs:
            hours = (left - entered).total_seconds() / 3600
            countries.append(
                {
                    "country": country,
                    "entered": _stamp(entered),
                    "left": _stamp(left),
                    "hours": round(hours, 1),
                }
            )
            foreign = country != home
            rate, currency = (
                FOREIGN_RATES.get(country, (None, "")) if foreign else (DOMESTIC_RATE, "PLN")
            )
            days = per_diem_days(hours, foreign, whole)
            row: dict[str, object] = {"country": country, "days": days, "currency": currency}
            if rate is not None:
                row["rate"] = _number(rate)
                row["amount"] = round(days * rate, 2)
                totals[currency] = totals.get(currency, 0.0) + days * rate
            diems.append(row)
        result.set("countries", countries, "route")
        result.set("per_diems", diems, "route")
        total = "; ".join(f"{amount:.2f} {cur}" for cur, amount in totals.items())
        result.set("per_diem_total", total, "route")
    result.set("notes", t("documents.text.trip_notes"), "auto")
    result.set("issued_date", src.today.isoformat(), "auto")


def _working_time(result: Prefill, src: Sources) -> None:
    result.set("company", company_block(src.company, src.profile), "company")
    result.set("driver_name", src.driver_name, "driver")
    _vehicle(result, src.vehicle)
    start, end = src.period or (src.today, src.today)
    result.set("period_from", start.isoformat(), "auto")
    result.set("period_to", end.isoformat(), "auto")
    days: dict[date, dict] = {}
    for trip in _period_trips(src):
        day = days.setdefault(
            trip.started_at.date(),
            {"start": trip.started_at, "end": trip.ended_at, "minutes": 0.0, "km": 0.0},
        )
        day["start"] = min(day["start"], trip.started_at)
        day["end"] = max(day["end"], trip.ended_at)
        minutes = (trip.ended_at - trip.started_at).total_seconds() / 60
        day["minutes"] += max(0.0, minutes - (trip.idle_min or 0))
        day["km"] += trip.distance_km
    rows = [
        {
            "date": day.isoformat(),
            "start": v["start"].strftime("%H:%M"),
            "end": v["end"].strftime("%H:%M"),
            "driving_h": round(v["minutes"] / 60, 1),
            "km": round(v["km"]),
        }
        for day, v in sorted(days.items())
    ]
    result.set("days", rows, "trips")
    if rows:
        total_h = sum(v["minutes"] for v in days.values()) / 60
        result.set("total_driving_h", round(total_h, 1), "trips")
        result.set("total_km", round(sum(v["km"] for v in days.values())), "trips")
    result.set("notes", t("documents.text.working_time_notes"), "auto")


SOON_DAYS = 30


def _check_row(name: str, until: date | None, today: date) -> dict[str, object]:
    row: dict[str, object] = {"mark": "", "document": t(f"documents.check.{name}")}
    if until is not None:
        row["valid_until"] = until.isoformat()
        status = (
            "expired"
            if until < today
            else "soon"
            if until <= today + timedelta(SOON_DAYS)
            else "ok"
        )
        row["status"] = t(f"documents.text.status_{status}")
    return row


def _cabin_checklist(result: Prefill, src: Sources) -> None:
    today = src.period[0] if src.period else src.today
    result.set("check_date", today.isoformat(), "auto")
    vehicle = src.vehicle
    if vehicle:
        result.set("vehicle", vehicle.name, "vehicle")
    _vehicle(result, vehicle)
    result.set("driver_name", src.driver_name, "driver")
    result.set("carrier", _carrier(src), "company")
    driver = src.driver.deadlines if src.driver else {}
    vdates = vehicle.deadlines if vehicle else {}
    hazmat = bool(vehicle and vehicle.hazmat)
    rows = [_check_row(n, driver.get(n), today) for n in ("license", "card", "code95")]
    rows += [_check_row(n, driver.get(n), today) for n in ("medical", "psych")]
    if hazmat or "adr" in driver:
        rows.append(_check_row("driver_adr", driver.get("adr"), today))
    if "attestation" in driver:
        rows.append(_check_row("attestation", driver["attestation"], today))
    rows.append(_check_row("inspection", vdates.get("inspection"), today))
    rows.append(_check_row("insurance", vdates.get("insurance"), today))
    if vehicle and vehicle.trailer_plate:
        rows.append(_check_row("trailer_inspection", vdates.get("trailer_inspection"), today))
        rows.append(_check_row("trailer_insurance", vdates.get("trailer_insurance"), today))
    ocp = _check_row("ocp", vdates.get("ocp"), today)
    if src.profile.ocp_policy and "valid_until" not in ocp:
        ocp["status"] = src.profile.ocp_policy
    rows.append(ocp)
    licence = _check_row("licence", None, today)
    if src.profile.licence_number:
        licence["status"] = src.profile.licence_number
    rows.append(licence)
    rows.append(_check_row("tachograph", vdates.get("tachograph"), today))
    if hazmat or "adr" in vdates or "trailer_adr" in vdates:
        adr = vdates.get("adr") or vdates.get("trailer_adr")
        rows.append(_check_row("vehicle_adr", adr, today))
        rows.append(_check_row("written_instructions", None, today))
    if "atp" in vdates or "trailer_atp" in vdates:
        rows.append(_check_row("atp", vdates.get("atp") or vdates.get("trailer_atp"), today))
    for name in ("cmr", "tacho_records", "posting", "permits"):
        rows.append(_check_row(name, None, today))
    result.set("checklist", rows, "auto")
    expired = [
        str(r["document"]) for r in rows if r.get("status") == t("documents.text.status_expired")
    ]
    if expired:
        result.warnings.append(t("documents.warn.expired", items=", ".join(expired)))


EQUIPMENT = (
    "registration",
    "insurance",
    "keys",
    "fuel_card",
    "fire_extinguisher",
    "warning_triangle",
    "first_aid",
    "vests",
    "wheel_chocks",
    "straps",
    "corners",
    "anti_slip_mats",
    "spare_wheel",
)


def _vehicle_handover(result: Prefill, src: Sources) -> None:
    result.set("handover_at", f"{src.today.isoformat()}", "auto")
    result.set("handover_place", src.profile.issue_place or src.profile.city, "profile")
    result.set("company", company_block(src.company, src.profile), "company")
    result.set("driver_name", src.driver_name, "driver")
    vehicle = src.vehicle
    if vehicle:
        result.set("vehicle", vehicle.name, "vehicle")
        result.set("odometer", vehicle.odometer_km, "vehicle")
    _vehicle(result, vehicle)
    items = list(EQUIPMENT) + (["adr_kit"] if vehicle and vehicle.hazmat else [])
    rows = [{"item": t(f"documents.equipment.{item}"), "count": "", "state": ""} for item in items]
    result.set("equipment", rows, "auto")
    result.set("notes", t("documents.text.handover_notes"), "auto")


PALLETS = ("euro", "industrial", "half")


def _pallet_note(result: Prefill, src: Sources) -> None:
    result.set("carrier", _carrier(src), "company")
    _vehicle(result, src.vehicle)
    result.set("driver_name", src.driver_name, "driver")
    _, last = _ends(src)
    if last:
        result.set("exchange_place", _place(last), "route")
        if last.at:
            result.set("exchange_at", _stamp(last.at), "route")
    if not last or not last.at:
        result.set("exchange_at", src.today.isoformat(), "auto")
    counts: dict[str, int] = {}
    for item in src.cargo.items if src.cargo else []:
        if item.kind in PALLETS:
            counts[item.kind] = counts.get(item.kind, 0) + item.count
    rows = [
        {"pallet_type": t(f"documents.packing.{kind}"), "delivered": count}
        for kind, count in counts.items()
    ]
    result.set("pallets", rows, "cargo")


def _securing(result: Prefill, src: Sources) -> None:
    result.set("carrier", _carrier(src), "company")
    _vehicle(result, src.vehicle)
    result.set("driver_name", src.driver_name, "driver")
    first, _ = _ends(src)
    if first:
        result.set("loading_place", _place(first), "route")
    if first and first.at:
        result.set("loaded_at", _stamp(first.at), "route")
    else:
        result.set("loaded_at", src.today.isoformat(), "auto")
    cargo = src.cargo
    if cargo:
        result.set("goods", _goods(cargo, "nature packages packing gross_kg"), "cargo")
        if cargo.items:
            total = sum(item.count * item.weight_kg for item in cargo.items)
            result.set("total_kg", _number(total), "cargo")
    result.set("statement", t("documents.text.securing_statement"), "auto")


def _adr_document(result: Prefill, src: Sources) -> None:
    result.set("carrier", _carrier(src), "company")
    first, last = _ends(src)
    if first:
        when = (first.at.date() if first.at else src.today).isoformat()
        result.set("loading_place_date", f"{_place(first)}\n{when}", "route")
    if last and last is not first:
        result.set("delivery_place", _place(last), "route")
    if src.cargo:
        result.set("dangerous_goods", src.cargo.dangerous_goods, "cargo")
    result.set("written_instructions", t("documents.text.adr_instructions"), "auto")
    _vehicle(result, src.vehicle)
    _issued(result, src)


def _sent(result: Prefill, src: Sources) -> None:
    result.set("carrier", _carrier(src), "company")
    result.set("driver_name", src.driver_name, "driver")
    first, last = _ends(src)
    if first:
        result.set("loading_place", _place(first), "route")
        if first.at:
            result.set("start_at", _stamp(first.at), "route")
    if last and last is not first:
        result.set("delivery_place", _place(last), "route")
    if src.route and src.route.duration_min is not None:
        result.set("duration_h", round(src.route.duration_min / 60, 1), "route")
    _vehicle(result, src.vehicle)
    if src.cargo:
        result.set("goods", _goods(src.cargo, "nature packages gross_kg"), "cargo")
    result.set("notes", t("documents.text.sent_notes"), "auto")


def _edd(result: Prefill, src: Sources) -> None:
    result.set("carrier", _carrier(src), "company")
    first, last = _ends(src)
    if first:
        result.set("loading_place", _place(first), "route")
    if last and last is not first:
        result.set("delivery_place", _place(last), "route")
    when = first.at.date() if first and first.at else src.today
    result.set("dispatch_date", when.isoformat(), "route" if first and first.at else "auto")
    _vehicle(result, src.vehicle)
    if src.cargo:
        rows = [
            {
                "nature": item.label,
                "quantity": item.count,
                "unit": t(f"documents.packing.{item.kind}"),
            }
            for item in src.cargo.items
        ]
        result.set("goods", rows, "cargo")
    result.set("notes", t("documents.text.edd_notes"), "auto")


def _oversize(result: Prefill, src: Sources) -> None:
    result.set("applicant", company_block(src.company, src.profile), "company")
    result.set("trips_count", 1, "auto")
    vehicle = src.vehicle
    _vehicle(result, vehicle)
    if vehicle:
        kind = vehicle.trailer_kind or vehicle.kind
        result.set("vehicle_type", t(f"documents.vehicle_kind.{kind}"), "vehicle")
    stops = src.route.stops if src.route else []
    if stops:
        description = " → ".join(_place(s) for s in stops)
        if src.route and src.route.distance_km is not None:
            description += f"\n{round(src.route.distance_km)} km"
        result.set("route_description", description, "route")
    start, end, source = _route_period(src)
    result.set("period_from", start.isoformat(), source)
    result.set("period_to", end.isoformat(), source)
    cargo = src.cargo
    if cargo and cargo.items:
        lines = [f"{item.count} × {item.label or item.kind}" for item in cargo.items]
        total = sum(item.count * item.weight_kg for item in cargo.items)
        lines.append(t("documents.text.cargo_weight", value=_number(total)))
        result.set("cargo_description", "\n".join(lines), "cargo")
    result.set("notes", t("documents.text.oversize_notes"), "auto")


FILLERS = {
    "cmr": _cmr,
    "transport_order": _order,
    "road_card": _road_card,
    "pod": _pod,
    "damage_report": _damage,
    "loading_report": _loading,
    "posting_declaration": _posting,
    "consignment_note": _consignment,
    "driver_activity": _driver_activity,
    "business_trip": _business_trip,
    "working_time": _working_time,
    "cabin_checklist": _cabin_checklist,
    "vehicle_handover": _vehicle_handover,
    "pallet_note": _pallet_note,
    "securing_declaration": _securing,
    "adr_document": _adr_document,
    "sent_data": _sent,
    "edd_data": _edd,
    "oversize_permit_data": _oversize,
}


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
