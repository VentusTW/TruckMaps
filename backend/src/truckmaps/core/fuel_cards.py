"""Import wyciągów z kart paliwowych (CSV) – tankowania jako wpisy ``fuel`` przy pojeździe.

Każdy wystawca (DKV, UTA, E100, Orlen Flota, Shell, BP, Circle K…) ma własny układ kolumn,
więc kolumny rozpoznajemy po nazwach nagłówków (polskie, angielskie, niemieckie), a separator,
kodowanie (UTF-8 / Windows-1250), format daty i liczb (przecinek dziesiętny) – z treści.

Pojazd: po numerze rejestracyjnym, a gdy wiersz go nie ma – po numerze karty (z innych wierszy
pliku albo wcześniejszych importów). Wiersze bez pojazdu trafiają do wpisów firmy, żeby koszt
nie zginął. Ponowny import tego samego wyciągu nie dubluje tankowań (klucz z daty, karty,
ilości i kwoty).
"""

import base64
import binascii
import csv
import io
import re
import unicodedata
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from truckmaps.core.companies import Company, membership, require_member
from truckmaps.core.currency import Rates, latest_rates
from truckmaps.core.db import get_session
from truckmaps.core.i18n import t
from truckmaps.core.records import WRITERS, EntityRecord
from truckmaps.core.vehicles import VehicleProfile
from truckmaps.sdk import Principal

KIND = "fuel"
MAX_BYTES = 10 * 1024 * 1024
MAX_ROWS = 50_000

COLUMNS: dict[str, tuple[str, ...]] = {
    "datetime": ("dataigodzina", "datagodzina", "datetime", "transactiondatetime", "datumuhrzeit"),
    "date": (
        "data", "datatransakcji", "datatankowania", "datadostawy", "date", "transactiondate",
        "deliverydate", "datum", "transaktionsdatum", "lieferdatum",
    ),
    "time": ("godzina", "czas", "godzinatransakcji", "time", "transactiontime", "uhrzeit", "zeit"),
    "plate": (
        "nrrejestracyjny", "numerrejestracyjny", "nrrej", "rejestracja", "tablica", "pojazd",
        "licenseplate", "registration", "registrationnumber", "vehicleregistration", "vehicle",
        "kennzeichen", "kfzkennzeichen", "fahrzeug",
    ),
    "card": (
        "karta", "nrkarty", "numerkarty", "card", "cardnumber", "cardno", "kartennummer", "karte",
    ),
    "liters": (
        "ilosc", "iloscl", "iloscwlitrach", "litry", "liczbalitrow", "liters", "litres", "quantity",
        "volume", "menge", "mengel", "liter",
    ),
    "amount": (
        "kwotabrutto", "wartoscbrutto", "brutto", "wartosc", "kwota", "dozaplaty", "amount",
        "grossamount", "amountgross", "total", "totalamount", "gross", "betrag", "bruttobetrag",
        "gesamtbetrag",
    ),
    "net": ("kwotanetto", "wartoscnetto", "netto", "netamount", "amountnet", "net", "nettobetrag"),
    "currency": ("waluta", "currency", "curr", "wahrung"),
    "product": (
        "produkt", "towar", "nazwaproduktu", "rodzajpaliwa", "paliwo", "product", "productname",
        "fuel", "fueltype", "artikel", "produktname", "warenbezeichnung",
    ),
    "odometer": (
        "przebieg", "licznik", "stanlicznika", "odometer", "mileage", "km", "kilometerstand",
    ),
    "station": ("stacja", "miejsce", "adres", "station", "location", "site", "tankstelle", "ort"),
    "country": ("kraj", "country", "land"),
    "driver": ("kierowca", "driver", "fahrer"),
    "unit_price": ("cenajednostkowa", "cena", "cenazalitr", "unitprice", "price", "preis"),
}  # fmt: skip
REQUIRED = ("liters", "amount")
DATE_FORMATS = ("%Y-%m-%d", "%d.%m.%Y", "%d-%m-%Y", "%d/%m/%Y", "%Y/%m/%d", "%d.%m.%y", "%Y%m%d")
TIME_FORMATS = ("%H:%M:%S", "%H:%M")


class FuelCsvError(ValueError):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


@dataclass
class Fueling:
    at: datetime
    liters: float
    amount: float
    currency: str = ""
    net: float | None = None
    product: str = ""
    product_type: str = "diesel"
    """diesel, adblue albo other (myjnia, opłaty, towary)."""
    plate: str = ""
    card: str = ""
    odometer: int | None = None
    station: str = ""
    country: str = ""
    driver: str = ""

    @property
    def key(self) -> str:
        return "|".join(
            [
                self.at.isoformat(), self.card, plate_key(self.plate), f"{self.liters:.2f}",
                f"{self.amount:.2f}", self.product.lower(),
            ]
        )  # fmt: skip


@dataclass
class Parsed:
    rows: list[Fueling] = field(default_factory=list)
    skipped: int = 0
    columns: dict[str, str] = field(default_factory=dict)
    """Rozpoznane pola → nagłówek z pliku."""


def _norm(text: str) -> str:
    folded = unicodedata.normalize("NFKD", text.replace("ł", "l").replace("Ł", "L"))
    return re.sub(r"[^0-9a-z]", "", folded.encode("ascii", "ignore").decode().lower())


def plate_key(plate: str | None) -> str:
    return re.sub(r"[^0-9A-Z]", "", (plate or "").upper())


def _number(text: str) -> float | None:
    value = re.sub(r"[^\d,.\-]", "", text.replace(" ", "").replace(" ", ""))
    if not value or value in "-.,":
        return None
    if "," in value and "." in value:
        if value.rfind(",") > value.rfind("."):
            value = value.replace(".", "").replace(",", ".")
        else:
            value = value.replace(",", "")
    elif "," in value:
        value = value.replace(",", ".")
    try:
        return float(value)
    except ValueError:
        return None


def _date(text: str, time_text: str = "") -> datetime | None:
    text = text.strip()
    if not text:
        return None
    for candidate in (text, f"{text} {time_text.strip()}".strip()):
        try:
            parsed = datetime.fromisoformat(candidate.replace("Z", "+00:00"))
            return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)
        except ValueError:
            pass
    day_part, _, rest = text.partition(" ")
    clock = (rest or time_text).strip()
    for day_format in DATE_FORMATS:
        try:
            day = datetime.strptime(day_part, day_format)
        except ValueError:
            continue
        for time_format in TIME_FORMATS:
            try:
                moment = datetime.strptime(clock, time_format)
                day = day.replace(hour=moment.hour, minute=moment.minute, second=moment.second)
                break
            except ValueError:
                continue
        return day.replace(tzinfo=UTC)
    return None


FUEL_WORDS = (
    "diesel", "olej", "napedow", "gasoil", "paliwo", "fuel", "kraftstoff", "lng", "cng", "lpg",
    "verva", "efecta", "vpower", "ultimate", "hvo", "benzyn", "pb95", "pb98", "eurosuper",
)  # fmt: skip


def product_type(product: str) -> str:
    """diesel (też inne paliwo i brak nazwy), adblue albo other."""
    name = _norm(product)
    if name == "def" or any(word in name for word in ("adblue", "urea", "harnstoff")):
        return "adblue"
    if not name or name in ("on", "dk", "d") or any(word in name for word in FUEL_WORDS):
        return "diesel"
    return "other"


def _decode(data: bytes) -> str:
    for encoding in ("utf-8-sig", "cp1250"):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            continue
    return data.decode("latin-1")


def _columns(header: list[str]) -> dict[str, int]:
    found: dict[str, int] = {}
    names = [_norm(h) for h in header]
    for field_name, aliases in COLUMNS.items():
        for i, name in enumerate(names):
            if name in aliases and i not in found.values():
                found[field_name] = i
                break
    for field_name, aliases in COLUMNS.items():
        if field_name in found:
            continue
        for i, name in enumerate(names):
            if i not in found.values() and any(len(a) >= 5 and a in name for a in aliases):
                found[field_name] = i
                break
    return found


def parse(data: bytes) -> Parsed:
    """Tankowania z pliku CSV (nagłówek w jednym z pierwszych 10 wierszy)."""
    text = _decode(data)
    sample = text[:20000]
    try:
        delimiter = csv.Sniffer().sniff(sample, delimiters=";,\t|").delimiter
    except csv.Error:
        delimiter = ";" if sample.count(";") >= sample.count(",") else ","
    lines = list(csv.reader(io.StringIO(text), delimiter=delimiter))
    columns: dict[str, int] = {}
    start = 0
    for index, line in enumerate(lines[:10]):
        columns = _columns(line)
        if all(c in columns for c in REQUIRED) and ("date" in columns or "datetime" in columns):
            start = index + 1
            break
    else:
        raise FuelCsvError("fuel.no_columns")
    result = Parsed(columns={k: lines[start - 1][i].strip() for k, i in columns.items()})

    def cell(row: list[str], name: str) -> str:
        i = columns.get(name)
        return row[i].strip() if i is not None and i < len(row) else ""

    for row in lines[start : start + MAX_ROWS]:
        if not any(c.strip() for c in row):
            continue
        at = _date(cell(row, "datetime") or cell(row, "date"), cell(row, "time"))
        liters = _number(cell(row, "liters"))
        amount = _number(cell(row, "amount"))
        if amount is None and (net := _number(cell(row, "net"))) is not None:
            amount = net
        if at is None or liters is None or amount is None:
            result.skipped += 1
            continue
        product = cell(row, "product")
        odometer = _number(cell(row, "odometer"))
        result.rows.append(
            Fueling(
                at=at, liters=round(liters, 3), amount=round(amount, 2),
                currency=cell(row, "currency").upper()[:3], net=_number(cell(row, "net")),
                product=product[:80], product_type=product_type(product),
                plate=cell(row, "plate")[:20], card=re.sub(r"\s", "", cell(row, "card"))[:30],
                odometer=int(odometer) if odometer else None, station=cell(row, "station")[:120],
                country=cell(row, "country")[:20], driver=cell(row, "driver")[:120],
            )
        )  # fmt: skip
    if not result.rows:
        raise FuelCsvError("fuel.no_rows")
    return result


class ImportIn(BaseModel):
    name: str = Field(min_length=1, max_length=200, examples=["dkv_2026-10.csv"])
    data: str = Field(description="Treść pliku CSV w base64")
    vehicle_id: str | None = Field(default=None, description="Wszystkie wiersze do tego pojazdu")
    currency: str = Field(default="PLN", min_length=3, max_length=3, description="Gdy brak w pliku")


class ImportOut(BaseModel):
    imported: int
    duplicates: int
    skipped: int
    unmatched: list[str]
    """Numery rejestracyjne / karty bez pojazdu w firmie (zapisane przy firmie)."""
    liters: float
    amount: dict[str, float]
    """Waluta → kwota zaimportowanych tankowań."""
    columns: dict[str, str]


class VehicleFuel(BaseModel):
    vehicle_id: str | None
    plate: str | None
    count: int
    liters: float
    adblue_liters: float
    amount: dict[str, float]
    total: float | None = None
    """Suma w walucie ``total_currency`` po kursie EBC; ``None`` – brak kursu którejś waluty."""
    last: datetime | None


class SummaryOut(BaseModel):
    since: datetime
    count: int
    liters: float
    amount: dict[str, float]
    total: float | None = None
    """Wszystkie kwoty przeliczone na ``total_currency`` (kurs EBC, szacunkowo)."""
    total_currency: str
    rates_day: date | None = None
    vehicles: list[VehicleFuel]


def _add(totals: dict[str, float], currency: str, amount: float) -> None:
    totals[currency] = round(totals.get(currency, 0) + amount, 2)


def convert_total(amounts: dict[str, float], rates: Rates, target: str) -> float | None:
    """Suma kwot w różnych walutach w walucie ``target``; ``None`` – brak kursu."""
    total = 0.0
    for currency, amount in amounts.items():
        value = rates.convert(amount, currency, target)
        if value is None:
            return None
        total += value
    return round(total, 2)


def build_router(current_user) -> APIRouter:
    router = APIRouter(tags=["fuel-cards"])
    User = Annotated[Principal, Depends(current_user)]
    Db = Annotated[Session, Depends(get_session)]

    def fuel_records(db: Session, company_id: str, since: datetime | None = None):
        query = select(EntityRecord).where(
            EntityRecord.company_id == company_id, EntityRecord.kind == KIND
        )
        rows = list(db.scalars(query))
        if since is None:
            return rows
        return [r for r in rows if str((r.data or {}).get("at", "")) >= since.isoformat()]

    @router.post("/api/companies/{company_id}/fuel-cards/import")
    def import_csv(company_id: str, data: ImportIn, user: User, db: Db) -> ImportOut:
        """Wczytuje wyciąg z karty paliwowej (CSV) – tankowania przy pojazdach."""
        require_member(db, company_id, user, WRITERS)
        try:
            content = base64.b64decode(data.data.split(",")[-1], validate=True)
        except (binascii.Error, ValueError) as error:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_CONTENT, t("fuel.bad_file")
            ) from error
        if len(content) > MAX_BYTES:
            raise HTTPException(status.HTTP_413_CONTENT_TOO_LARGE, t("fuel.too_large", mb=10))
        try:
            parsed = parse(content)
        except FuelCsvError as error:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, t(error.code)) from error
        vehicles = list(
            db.scalars(select(VehicleProfile).where(VehicleProfile.company_id == company_id))
        )
        forced = None
        if data.vehicle_id:
            forced = next((v for v in vehicles if v.id == data.vehicle_id), None)
            if forced is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, t("error.vehicle_not_found"))
        by_plate = {plate_key(v.plate): v.id for v in vehicles if v.plate}
        existing = fuel_records(db, company_id)
        keys = {str((r.data or {}).get("key")) for r in existing}
        by_card: dict[str, str] = {}
        for record in existing:
            card = (record.data or {}).get("card")
            if card and record.entity_type == "vehicle":
                by_card[card] = record.entity_id
        for row in parsed.rows:
            vehicle_id = by_plate.get(plate_key(row.plate))
            if row.card and vehicle_id:
                by_card[row.card] = vehicle_id
        imported = duplicates = 0
        unmatched: set[str] = set()
        liters = 0.0
        totals: dict[str, float] = {}
        for row in parsed.rows:
            if row.key in keys:
                duplicates += 1
                continue
            keys.add(row.key)
            vehicle_id = (
                forced.id if forced else by_plate.get(plate_key(row.plate)) or by_card.get(row.card)
            )
            if vehicle_id is None:
                unmatched.add(row.plate or row.card or "–")
            currency = row.currency or data.currency.upper()
            db.add(
                EntityRecord(
                    company_id=company_id,
                    entity_type="vehicle" if vehicle_id else "company",
                    entity_id=vehicle_id or company_id,
                    kind=KIND,
                    data={
                        "key": row.key, "at": row.at.isoformat(), "liters": row.liters,
                        "amount": row.amount, "net": row.net, "currency": currency,
                        "product": row.product, "product_type": row.product_type,
                        "plate": row.plate, "card": row.card, "odometer": row.odometer,
                        "station": row.station, "country": row.country, "driver": row.driver,
                        "source": data.name,
                    },
                    created_by=user.subject,
                )
            )  # fmt: skip
            imported += 1
            if row.product_type == "diesel":
                # Jak w podsumowaniu: litry paliwa, bez AdBlue i towarów.
                liters += row.liters
            _add(totals, currency, row.amount)
        db.commit()
        return ImportOut(
            imported=imported, duplicates=duplicates, skipped=parsed.skipped,
            unmatched=sorted(unmatched), liters=round(liters, 2), amount=totals,
            columns=parsed.columns,
        )  # fmt: skip

    @router.get("/api/companies/{company_id}/fuel-cards/summary")
    def summary(
        company_id: str,
        user: User,
        db: Db,
        months: Annotated[int, Query(ge=1, le=36)] = 3,
        currency: Annotated[str | None, Query(min_length=3, max_length=3)] = None,
    ) -> SummaryOut:
        """Tankowania z kart z ostatnich ``months`` miesięcy: razem i według pojazdów.

        Kwoty zostają w walutach wyciągu, obok suma przeliczona na ``currency`` (domyślnie
        waluta kosztów firmy) po ostatnim kursie EBC.
        """
        if membership(db, company_id, user) is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("error.company_not_found"))
        company = db.get(Company, company_id)
        target = (currency or (company.cost_currency if company else None) or "PLN").upper()
        rates = latest_rates(db)
        since = datetime.now(UTC) - timedelta(days=30 * months)
        plates = {
            v.id: v.plate
            for v in db.scalars(
                select(VehicleProfile).where(VehicleProfile.company_id == company_id)
            )
        }
        groups: dict[str | None, VehicleFuel] = {}
        totals: dict[str, float] = {}
        liters = 0.0
        records = fuel_records(db, company_id, since)
        for record in records:
            item = record.data or {}
            vehicle_id = record.entity_id if record.entity_type == "vehicle" else None
            group = groups.setdefault(
                vehicle_id,
                VehicleFuel(
                    vehicle_id=vehicle_id, plate=plates.get(vehicle_id) if vehicle_id else None,
                    count=0, liters=0, adblue_liters=0, amount={}, last=None,
                ),
            )  # fmt: skip
            amount = float(item.get("amount") or 0)
            volume = float(item.get("liters") or 0)
            currency = str(item.get("currency") or "PLN")
            group.count += 1
            if item.get("product_type") == "adblue":
                group.adblue_liters = round(group.adblue_liters + volume, 2)
            elif item.get("product_type") != "other":
                group.liters = round(group.liters + volume, 2)
                liters += volume
            _add(group.amount, currency, amount)
            _add(totals, currency, amount)
            at = datetime.fromisoformat(str(item["at"])) if item.get("at") else None
            if at and (group.last is None or at > group.last):
                group.last = at
        for group in groups.values():
            group.total = convert_total(group.amount, rates, target)
        return SummaryOut(
            since=since,
            count=len(records),
            liters=round(liters, 2),
            amount=totals,
            total=convert_total(totals, rates, target),
            total_currency=target,
            rates_day=rates.day,
            vehicles=sorted(groups.values(), key=lambda g: -g.liters),
        )

    return router
