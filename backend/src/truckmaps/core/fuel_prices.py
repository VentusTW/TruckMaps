"""Ceny oleju napędowego w krajach UE z Weekly Oil Bulletin Komisji Europejskiej.

Biuletyn jest darmowy i wychodzi co tydzień (ceny z poniedziałku, z podatkami, w euro za
1000 l). Adres pliku zmienia się co tydzień, więc szukamy go na stronie biuletynu. Ceny
trzymamy w bazie z datą – gdy strona jest nieosiągalna, liczymy po ostatnich znanych.
Pliku xlsx nie otwieramy żadną biblioteką: to archiwum zip z arkuszem w XML.
"""

import io
import logging
import re
import threading
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from dataclasses import dataclass, field
from datetime import date, timedelta
from urllib.parse import urljoin

from sqlalchemy import Date, String, func, select
from sqlalchemy.orm import Mapped, Session, mapped_column

from truckmaps.core.db import Base, Database

log = logging.getLogger(__name__)

REFRESH_EVERY_S = 12 * 3600
FETCH_TIMEOUT_S = 30
# Link „Prices with taxes – latest prices (xlsx)” na stronie biuletynu.
LINK = re.compile(r'href="([^"]*with%20Taxes[^"]*\.xlsx)"', re.IGNORECASE)
# Dzień zero dat w Excelu (liczba dni od 1899-12-30).
EXCEL_EPOCH = date(1899, 12, 30)

COUNTRIES = {
    "Austria": "AT", "Belgium": "BE", "Bulgaria": "BG", "Croatia": "HR", "Cyprus": "CY",
    "Czechia": "CZ", "Czech Republic": "CZ", "Denmark": "DK", "Estonia": "EE", "Finland": "FI",
    "France": "FR", "Germany": "DE", "Greece": "GR", "Hungary": "HU", "Ireland": "IE",
    "Italy": "IT", "Latvia": "LV", "Lithuania": "LT", "Luxembourg": "LU", "Malta": "MT",
    "Netherlands": "NL", "Poland": "PL", "Portugal": "PT", "Romania": "RO", "Slovakia": "SK",
    "Slovenia": "SI", "Spain": "ES", "Sweden": "SE",
}  # fmt: skip


class FuelPrice(Base):
    __tablename__ = "fuel_prices"

    day: Mapped[date] = mapped_column(Date, primary_key=True)
    country: Mapped[str] = mapped_column(String(2), primary_key=True)
    diesel_eur: Mapped[float]
    """Olej napędowy z podatkami, euro za litr."""


@dataclass(frozen=True)
class Prices:
    day: date | None = None
    """Data cen z biuletynu; ``None`` – jeszcze nie pobrano."""
    diesel_eur: dict[str, float] = field(default_factory=dict)
    """Kraj (ISO) → euro za litr ON."""


def latest(db: Session) -> Prices:
    day = db.scalar(select(func.max(FuelPrice.day)))
    if day is None:
        return Prices()
    rows = db.scalars(select(FuelPrice).where(FuelPrice.day == day))
    return Prices(day=day, diesel_eur={r.country: r.diesel_eur for r in rows})


def _cells(sheet: bytes, strings: list[str]) -> dict[str, str]:
    """Komórki arkusza: adres (np. "C23") → tekst albo liczba jako tekst."""
    ns = {"x": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
    cells = {}
    for c in ET.fromstring(sheet).iterfind(".//x:sheetData/x:row/x:c", ns):
        value = c.find("x:v", ns)
        if value is None or value.text is None:
            continue
        text = value.text
        if c.get("t") == "s":
            text = strings[int(text)]
        cells[c.get("r", "")] = text
    return cells


def parse_bulletin(xlsx: bytes) -> tuple[date, dict[str, float]]:
    """Arkusz „Prices with taxes”: A2 – data, w wierszach kraj (A) i ON w euro za 1000 l (C)."""
    ns = {"x": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
    with zipfile.ZipFile(io.BytesIO(xlsx)) as archive:
        strings = []
        if "xl/sharedStrings.xml" in archive.namelist():
            root = ET.fromstring(archive.read("xl/sharedStrings.xml"))
            strings = ["".join(si.itertext()) for si in root.iterfind("x:si", ns)]
        cells = _cells(archive.read("xl/worksheets/sheet1.xml"), strings)
    day = EXCEL_EPOCH + timedelta(days=int(float(cells["A2"])))
    prices = {}
    for ref, name in cells.items():
        row = ref[1:]
        if ref[0] != "A" or not row.isdigit() or name.strip() not in COUNTRIES:
            continue
        diesel = cells.get(f"C{row}")
        if diesel:
            prices[COUNTRIES[name.strip()]] = round(float(diesel) / 1000, 4)
    if not prices:
        raise ValueError("Brak cen ON w pliku biuletynu.")
    return day, prices


def find_link(page: str, page_url: str) -> str:
    found = LINK.search(page)
    if found is None:
        raise ValueError("Brak linku do cen z podatkami na stronie biuletynu.")
    return urljoin(page_url, found.group(1).replace("&amp;", "&"))


def store(db: Session, day: date, prices: dict[str, float]) -> bool:
    """Zapisuje ceny z danego tygodnia; ``False``, gdy już były."""
    if db.scalar(select(FuelPrice.day).where(FuelPrice.day == day).limit(1)):
        return False
    db.add_all(FuelPrice(day=day, country=c, diesel_eur=p) for c, p in prices.items())
    db.commit()
    return True


def _get(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=FETCH_TIMEOUT_S) as response:  # noqa: S310
        return response.read()


def refresh(database: Database, page_url: str) -> date:
    link = find_link(_get(page_url).decode("utf-8", "replace"), page_url)
    day, prices = parse_bulletin(_get(link))
    with database.session() as db:
        if store(db, day, prices):
            log.info("Ceny ON z biuletynu KE z %s zapisane (%d krajów)", day, len(prices))
    return day


class PriceUpdater:
    """Wątek w tle: ceny paliwa przy starcie serwera i potem co kilka godzin."""

    def __init__(self, database: Database, url: str) -> None:
        self._database, self._url = database, url
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, name="ceny-paliwa", daemon=True)

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                refresh(self._database, self._url)
            except Exception as exc:  # noqa: BLE001 – brak sieci nie może zatrzymać serwera
                log.warning("Nie udało się pobrać cen paliwa z biuletynu KE: %s", exc)
            self._stop.wait(REFRESH_EVERY_S)
