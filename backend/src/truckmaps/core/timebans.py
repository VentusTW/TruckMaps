"""Zakazy ruchu ciężarówek w czasie: niedziele, święta i wakacje – według przepisów państw.

Bezpieczeństwo i legalność przejazdu są w rdzeniu (za darmo). Dla każdego odcinka trasy
liczymy godzinę wjazdu (wyjazd + czas jazdy z silnika tras, bez przerw) i sprawdzamy zakazy
kraju, w którym odcinek leży – z kalendarzem świąt kraju i regionu (np. landu w DE).

Źródła (stan na 10.2026):
- PL: rozporządzenie MT z 31.07.2007 w sprawie okresowych ograniczeń oraz zakazu ruchu
  niektórych rodzajów pojazdów na drogach (t.j. Dz.U. 2021 poz. 783), § 1–2;
- DE: § 30 ust. 3–4 StVO (niedziele i święta), Ferienreiseverordnung § 1 (soboty w wakacje);
- CZ: § 43 zákona č. 361/2000 Sb.;
- SK: § 39 zákona č. 8/2009 Z. z. – według zestawień przewoźników, bez sprawdzenia tekstu
  ustawy, dlatego ostrzeżenia dla SK są oznaczone „sprawdź”;
- LT: brak ogólnego zakazu dla ciężarówek.

Wyjątki (np. towary szybko psujące się, zwierzęta, transport kombinowany) zależą od ładunku
i nie są sprawdzane – planer o nich przypomina.
"""

from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from functools import lru_cache
from zoneinfo import ZoneInfo

from pydantic import BaseModel

from truckmaps.core.restrictions import distance_m
from truckmaps.core.vehicles import VehicleIn

ZONES = {
    "PL": ZoneInfo("Europe/Warsaw"),
    "DE": ZoneInfo("Europe/Berlin"),
    "CZ": ZoneInfo("Europe/Prague"),
    "SK": ZoneInfo("Europe/Bratislava"),
    "LT": ZoneInfo("Europe/Vilnius"),
}
HOME_ZONE = ZONES["PL"]
COUNTRY_NAMES = {"PL": "w Polsce", "DE": "w Niemczech", "CZ": "w Czechach", "SK": "na Słowacji"}
# Autostrady, drogi ekspresowe i drogi krajowe I klasy (CZ, SK).
MAIN_ROADS = frozenset({"motorway", "trunk", "primary"})
# Ferienreiseverordnung § 1: drogi z sobotnim zakazem w wakacje (tylko wymienione odcinki).
DE_SUMMER_ROADS = frozenset(
    {
        "A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8", "A9", "A10", "A45", "A61", "A67", "A81",
        "A92", "A93", "A99", "A113", "A115", "A831", "A980", "A995", "B31", "B96",
    }
)  # fmt: skip
WEEKDAYS = ("pon.", "wt.", "śr.", "czw.", "pt.", "sob.", "niedz.")


def easter(year: int) -> date:
    """Niedziela Wielkanocna (algorytm Meeusa/Jonesa/Butchera, kalendarz gregoriański)."""
    a, b, c = year % 19, year // 100, year % 100
    d, e = b // 4, b % 4
    f = (b + 8) // 25
    g = (b - f + 1) // 3
    h = (19 * a + b - d - g + 15) % 30
    i, k = c // 4, c % 4
    m = (32 + 2 * e + 2 * i - h - k) % 7
    n = (a + 11 * h + 22 * m) // 451
    month, day = divmod(h + m - 7 * n + 114, 31)
    return date(year, month, day + 1)


@lru_cache
def pl_holidays(year: int) -> dict[date, str]:
    """Dni ustawowo wolne objęte zakazem (§ 2 pkt 1 rozporządzenia) – bez 6 stycznia."""
    e = easter(year)
    return {
        date(year, 1, 1): "Nowy Rok",
        e: "Wielkanoc",
        e + timedelta(days=1): "Poniedziałek Wielkanocny",
        date(year, 5, 1): "Święto Pracy",
        date(year, 5, 3): "Święto Konstytucji 3 Maja",
        e + timedelta(days=49): "Zielone Świątki",
        e + timedelta(days=60): "Boże Ciało",
        date(year, 8, 15): "Wniebowzięcie NMP",
        date(year, 11, 1): "Wszystkich Świętych",
        date(year, 11, 11): "Narodowe Święto Niepodległości",
        date(year, 12, 25): "Boże Narodzenie",
        date(year, 12, 26): "drugi dzień Bożego Narodzenia",
    }


# Dzień przed tymi świętami: zakaz 18–22 (§ 2 pkt 2 – lit. b–j, bez Nowego Roku i Świąt).
PL_EVE_EXCLUDED = ("Nowy Rok", "Boże Narodzenie", "drugi dzień Bożego Narodzenia")


@lru_cache
def pl_summer(year: int) -> tuple[date, date]:
    """Wakacje szkolne: od piątku po 20 czerwca do ostatniej niedzieli przed 1. dniem szkoły.

    Zajęcia kończą się w najbliższy piątek po 20 czerwca, a zaczynają w pierwszy dzień
    powszedni września – gdy wypada w piątek lub sobotę, w najbliższy poniedziałek.
    """
    june_20 = date(year, 6, 20)
    end_of_school = june_20 + timedelta(days=(4 - june_20.weekday()) % 7 or 7)
    first = date(year, 9, 1)
    while first.weekday() >= 4:  # pt., sob., niedz. → poniedziałek
        first += timedelta(days=1)
    return end_of_school, first - timedelta(days=first.weekday() + 1)


DE_REGIONAL = {
    "Fronleichnam": {"BW", "BY", "HE", "NW", "RP", "SL"},
    "Reformationstag": {"BB", "HB", "HH", "MV", "NI", "SN", "ST", "SH", "TH"},
    "Allerheiligen": {"BW", "BY", "NW", "RP", "SL"},
}


@lru_cache
def de_holidays(year: int, state: str) -> dict[date, str]:
    """Święta z § 30 ust. 4 StVO; regionalne tylko w wymienionych landach."""
    e = easter(year)
    days = {
        date(year, 1, 1): "Neujahr",
        e - timedelta(days=2): "Karfreitag",
        e + timedelta(days=1): "Ostermontag",
        date(year, 5, 1): "Tag der Arbeit",
        e + timedelta(days=39): "Christi Himmelfahrt",
        e + timedelta(days=50): "Pfingstmontag",
        date(year, 10, 3): "Tag der Deutschen Einheit",
        date(year, 12, 25): "1. Weihnachtstag",
        date(year, 12, 26): "2. Weihnachtstag",
    }
    regional = {
        e + timedelta(days=60): "Fronleichnam",
        date(year, 10, 31): "Reformationstag",
        date(year, 11, 1): "Allerheiligen",
    }
    days |= {d: name for d, name in regional.items() if state in DE_REGIONAL[name]}
    return days


@lru_cache
def cz_holidays(year: int) -> dict[date, str]:
    e = easter(year)
    return {
        date(year, 1, 1): "Nový rok",
        e - timedelta(days=2): "Velký pátek",
        e + timedelta(days=1): "Velikonoční pondělí",
        date(year, 5, 1): "Svátek práce",
        date(year, 5, 8): "Den vítězství",
        date(year, 7, 5): "Cyril a Metoděj",
        date(year, 7, 6): "Jan Hus",
        date(year, 9, 28): "Den české státnosti",
        date(year, 10, 28): "Vznik Československa",
        date(year, 11, 17): "Den boje za svobodu a demokracii",
        date(year, 12, 24): "Štědrý den",
        date(year, 12, 25): "1. svátek vánoční",
        date(year, 12, 26): "2. svátek vánoční",
    }


@lru_cache
def sk_holidays(year: int) -> dict[date, str]:
    """Dni pracovného pokoja (bez dni, które od 2025 r. straciły ten status)."""
    e = easter(year)
    return {
        date(year, 1, 1): "Deň vzniku SR",
        date(year, 1, 6): "Zjavenie Pána",
        e - timedelta(days=2): "Veľký piatok",
        e + timedelta(days=1): "Veľkonočný pondelok",
        date(year, 5, 1): "Sviatok práce",
        date(year, 7, 5): "Cyril a Metod",
        date(year, 8, 29): "Výročie SNP",
        date(year, 11, 1): "Sviatok všetkých svätých",
        date(year, 12, 24): "Štedrý deň",
        date(year, 12, 25): "1. sviatok vianočný",
        date(year, 12, 26): "2. sviatok vianočný",
    }


def is_holiday(country: str, day: date, state: str = "") -> bool:
    """Święto państwowe (dla ``PH`` w godzinach ograniczeń OSM)."""
    calendars = {
        "PL": lambda: pl_holidays(day.year),
        "DE": lambda: de_holidays(day.year, state),
        "CZ": lambda: cz_holidays(day.year),
        "SK": lambda: sk_holidays(day.year),
    }
    return country in calendars and day in calendars[country]()


@dataclass(frozen=True)
class Window:
    start: datetime
    end: datetime
    title: str
    """Np. "niedziele i święta (Allerheiligen)"."""
    roads: frozenset[str] | None = None
    """Klasy dróg objętych zakazem; ``None`` – wszystkie drogi."""
    refs: frozenset[str] | None = None
    """Numery dróg objętych zakazem (DE w wakacje); ``None`` – bez ograniczenia."""
    verified: bool = True
    """``False`` – przepis niepotwierdzony w tekście ustawy albo zależny od odcinka: „sprawdź”."""


def applies(country: str, vehicle: VehicleIn) -> bool:
    gvw = vehicle.gvw_t or vehicle.weight_t
    trailer = vehicle.trailer_type != "none"
    if country == "PL":
        return gvw > 12  # pojazdy i zespoły pojazdów o DMC powyżej 12 t
    if country == "DE":
        return gvw > 7.5 or trailer
    if country in ("CZ", "SK"):
        return gvw > 7.5 or (gvw > 3.5 and trailer)
    return False


@lru_cache(maxsize=4096)
def windows(country: str, day: date, state: str = "") -> tuple[Window, ...]:
    """Zakazy obowiązujące w danym kraju (i regionie) danego dnia, w czasie lokalnym."""
    zone = ZONES.get(country)
    if zone is None:
        return ()

    def at(hour: int) -> datetime:
        return datetime.combine(day, time(hour), zone)

    found: list[Window] = []
    sunday = day.weekday() == 6
    if country == "PL":
        holidays = pl_holidays(day.year)
        if day in holidays:
            found.append(Window(at(8), at(22), f"święto ({holidays[day]})"))
        tomorrow = holidays.get(day + timedelta(days=1))
        if tomorrow and tomorrow not in PL_EVE_EXCLUDED and day not in holidays:
            found.append(Window(at(18), at(22), f"dzień przed świętem ({tomorrow})"))
        first, last = pl_summer(day.year)
        if first <= day <= last:
            hours = {4: (18, 22, "piątek"), 5: (8, 14, "sobota"), 6: (8, 22, "niedziela")}
            if day.weekday() in hours and day not in holidays:
                start, end, name = hours[day.weekday()]
                found.append(Window(at(start), at(end), f"wakacje – {name}"))
    elif country == "DE":
        holiday = de_holidays(day.year, state).get(day)
        if sunday or holiday:
            title = f"święto ({holiday})" if holiday else "niedziela"
            found.append(Window(at(0), at(22), title))
        if day.weekday() == 5 and (7, 1) <= (day.month, day.day) <= (8, 31):
            found.append(
                Window(at(7), at(20), "soboty w wakacje (wybrane drogi)", refs=DE_SUMMER_ROADS,
                       verified=False)
            )  # fmt: skip
    elif country == "CZ":
        holiday = cz_holidays(day.year).get(day)
        if sunday or holiday:
            title = f"svátek ({holiday})" if holiday else "niedziela"
            found.append(Window(at(13), at(22), title, roads=MAIN_ROADS))
        if (7, 1) <= (day.month, day.day) <= (8, 31) and not holiday:
            if day.weekday() == 4:
                found.append(Window(at(17), at(21), "wakacje – piątek", roads=MAIN_ROADS))
            elif day.weekday() == 5:
                found.append(Window(at(7), at(13), "wakacje – sobota", roads=MAIN_ROADS))
    elif country == "SK":
        holiday = sk_holidays(day.year).get(day)
        if sunday or holiday:
            title = f"sviatok ({holiday})" if holiday else "niedziela"
            found.append(Window(at(0), at(22), title, roads=MAIN_ROADS, verified=False))
        if day.weekday() == 5 and (7, 1) <= (day.month, day.day) <= (8, 31) and not holiday:
            found.append(
                Window(at(7), at(19), "wakacje – sobota", roads=MAIN_ROADS, verified=False)
            )
    return tuple(found)


def _ref(name: str) -> str:
    return name.replace(" ", "").upper()


def _on_road(window: Window, road_class: str, names: list[str]) -> bool:
    if window.roads is not None and road_class not in window.roads:
        return False
    return window.refs is None or any(_ref(n) in window.refs for n in names)


class TimeBan(BaseModel):
    """Odcinek trasy, na który pojazd wjedzie w czasie zakazu ruchu."""

    country: str
    title: str
    message: str
    starts_at: datetime
    ends_at: datetime
    enter_at: datetime
    """Kiedy pojazd będzie na początku tego odcinka (czas jazdy bez przerw)."""
    wait_min: int
    """Ile trzeba by czekać na koniec zakazu, stojąc przed tym odcinkiem."""
    verified: bool
    index: int
    end_index: int
    lon: float
    lat: float
    km: float
    parkings: list = []
    """Parkingi przed tym odcinkiem (uzupełnia planer tras)."""


def _fmt(moment: datetime, zone: ZoneInfo) -> str:
    local = moment.astimezone(zone)
    return f"{WEEKDAYS[local.weekday()]} {local:%d.%m} {local:%H:%M}"


class TimeBanCheck(BaseModel):
    bans: list[TimeBan]
    wait_min: int
    """Łączny postój w czasie zakazów (pojazd czeka przed odcinkiem do końca zakazu)."""
    arrival: datetime
    """Przyjazd z postojami w czasie zakazów (czas jazdy bez przerw kierowcy)."""
    free_departure: datetime | None = None
    """Najbliższy późniejszy wyjazd bez postoju w czasie zakazów; ``None`` – nie szukano
    (brak zakazów) albo nie ma takiego w ``FREE_SEARCH_H``."""


# Szukanie wyjazdu bez zakazów: co pół godziny, najwyżej trzy doby naprzód.
FREE_STEP_MIN = 30
FREE_SEARCH_H = 72


def check_route(route, vehicle: VehicleIn, departure: datetime) -> TimeBanCheck:
    """Zakazy ruchu, w które trafi pojazd wyjeżdżający o ``departure`` (czas ze strefą).

    Przy zakazie potwierdzonym pojazd czeka przed odcinkiem do jego końca, więc dalsze
    odcinki liczone są z tym postojem. Zakaz niepewny („sprawdź” – np. tylko na wybranych
    odcinkach) jest ostrzeżeniem bez postoju.
    """
    bans, wait_s, arrival = _simulate(route, vehicle, departure)
    result = TimeBanCheck(bans=bans, wait_min=round(wait_s / 60), arrival=arrival)
    if wait_s:
        step = timedelta(minutes=FREE_STEP_MIN)
        later = _next_step(departure, step)
        while later <= departure + timedelta(hours=FREE_SEARCH_H):
            if not _simulate(route, vehicle, later, quick=True)[1]:
                result.free_departure = later
                break
            later += step
    return result


def _next_step(moment: datetime, step: timedelta) -> datetime:
    rounded = moment.replace(minute=0, second=0, microsecond=0)
    while rounded <= moment:
        rounded += step
    return rounded


def _simulate(route, vehicle: VehicleIn, departure: datetime, quick: bool = False):
    edges = [e for e in route.edges or [] if e.end_s is not None]
    end = departure + timedelta(minutes=route.duration_min)
    if not edges:
        return [], 0.0, end
    # Czas z dopasowania odcinków skalowany do czasu całej trasy z silnika tras.
    total_s = edges[-1].end_s or 1.0
    scale = route.duration_min * 60 / total_s if route.duration_min else 1.0
    cumulative = [0.0]
    if not quick:
        for (lon1, lat1), (lon2, lat2) in zip(route.geometry, route.geometry[1:], strict=False):
            cumulative.append(cumulative[-1] + distance_m(lon1, lat1, lon2, lat2))

    found: list[TimeBan] = []
    last_key = None
    begin_s = wait_s = 0.0
    for edge in edges:
        t0 = departure + timedelta(seconds=begin_s * scale + wait_s)
        t1 = departure + timedelta(seconds=edge.end_s * scale + wait_s)
        begin_s = edge.end_s
        if not edge.country or not applies(edge.country, vehicle):
            continue
        zone = ZONES[edge.country]
        days = {t0.astimezone(zone).date(), t1.astimezone(zone).date()}
        hit = next(
            (
                w
                for day in sorted(days)
                for w in windows(edge.country, day, edge.state)
                if t0 < w.end and t1 > w.start and _on_road(w, edge.road_class, edge.names)
                and (w.verified or not quick)
            ),
            None,
        )  # fmt: skip
        if hit is None:
            continue
        key = (edge.country, hit.title, hit.start)
        if key == last_key:
            found[-1].end_index = edge.end_index
            continue
        last_key = key
        enter = max(t0, hit.start)
        wait = max((hit.end - enter).total_seconds(), 0.0)
        if hit.verified:
            wait_s += wait  # postój przed odcinkiem do końca zakazu
        if quick:
            if wait_s:
                break
            continue
        index = min(edge.begin_index, len(route.geometry) - 1)
        lon, lat = route.geometry[index]
        then = (
            f" Postój do {_fmt(hit.end, zone)}."
            if hit.verified
            else " Sprawdź, czy dotyczy tego odcinka."
        )
        where = (
            "Wyjazd w czasie zakazu."
            if enter <= departure + timedelta(minutes=1)
            else f"Pojazd będzie tu ok. {_fmt(enter, zone)}."
        )
        found.append(
            TimeBan(
                country=edge.country,
                title=hit.title,
                message=(
                    f"Zakaz ruchu ciężarówek {COUNTRY_NAMES[edge.country]}: {hit.title}, "
                    f"{_fmt(hit.start, zone)}–{hit.end.astimezone(zone):%H:%M}. "
                    f"{where}{then}"
                ),
                starts_at=hit.start,
                ends_at=hit.end,
                enter_at=enter,
                wait_min=round(wait / 60),
                verified=hit.verified,
                index=index,
                end_index=edge.end_index,
                lon=lon,
                lat=lat,
                km=round(cumulative[index] / 1000, 1),
            )
        )
    return found, wait_s, end + timedelta(seconds=wait_s)
