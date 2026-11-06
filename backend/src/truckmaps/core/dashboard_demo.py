# ruff: noqa: E501 – długie teksty pokazowe w jednej linii
"""Dane pokazowe pulpitu głównego – treść z projektu Google Stitch („Główny Pulpit Operacyjny”).

Użycie (z katalogu z plikiem ``.env``)::

    python -m truckmaps.core.dashboard_demo --list
    python -m truckmaps.core.dashboard_demo --company "Nazwa firmy"   # albo id
    python -m truckmaps.core.dashboard_demo --company <id> --remove
    python -m truckmaps.core.dashboard_demo --company <id> --vehicles          # tabor pokazowy
    python -m truckmaps.core.dashboard_demo --company <id> --vehicles --remove

Tabor pokazowy to zwykłe pojazdy i członkowie firmy (VIN ``DEMO…``, konta ``demo-…``) – ekran
„Pojazdy i Tabor” czyta je tym samym API co prawdziwe.

W treści: ``**tekst**`` – pogrubienie, ``!!tekst!!`` – pogrubienie w kolorze alarmu.
Ikony – nazwy z listy obsługiwanej przez aplikację (np. ``truck``, ``timer``, ``route``).
"""

import argparse
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from truckmaps.core.companies import Company, CompanyMember
from truckmaps.core.config import Settings, load_env_file
from truckmaps.core.dashboard import DashboardScreen
from truckmaps.core.db import Database
from truckmaps.core.trips import VehicleTrip
from truckmaps.core.vehicles import VehicleProfile

STITCH = {
    "greeting_name": "Michale",
    "user_title": "Główny Dyspozytor",
    "edition": "TMS PRO",
    "edition_note": "Wydanie Flotowe v4.2",
    "shift": "Zmiana Dzienna (06:00 – 18:00)",
    "fleet_ok": "98.4%",
    "description": "Centrum Koordynacji Flotowej • Główny węzeł PL-WAW-01 • Nadzór w czasie rzeczywistym "
    "nad 323 jednostkami taboru ciężkiego",
    "base": "PL-WAW-01 (Baza Wesoła)",
    "notifications": {"alerts": True, "notifications": True},
    "telemetry": {
        "label": "Telemetria CAN",
        "percent": "98.4%",
        "active": 318,
        "total": 323,
        "gps": "Satelity: Fix OK",
    },
    "kpis": [
        {
            "label": "Aktywne zestawy w trasie",
            "icon": "truck",
            "value": "284",
            "unit": "/ 323 ciągniki",
            "left": "88% utylizacji",
            "left_icon": "trending_up",
            "left_tone": "primary",
            "right": "+12 vs wczoraj",
            "bar": 0.88,
            "bar_tone": "primary",
        },
        {
            "label": "Punktualność dostaw (on-time)",
            "icon": "schedule",
            "value": "97.2%",
            "unit": "SLA: 95.0%",
            "left": "14 opóźnień monitorowanych",
            "left_icon": "dot",
            "left_tone": "error",
            "right": "Śr. 22 min",
            "bar": 0.972,
            "bar_tone": "tertiary",
        },
        {
            "label": "Średnie zużycie paliwa",
            "icon": "fuel",
            "value": "27.8",
            "unit": "L / 100km",
            "left": "Score: 89/100",
            "left_icon": "eco",
            "left_tone": "success",
            "right": "-0.6 L vs cel",
            "right_tone": "success",
            "bar": 0.6,
            "bar_tone": "mint",
        },
        {
            "label": "Rentowność przewozów (dziś)",
            "icon": "payments",
            "value": "142 800",
            "unit": "PLN marży",
            "left": "89% planu dziennego",
            "left_tone": "primary",
            "right": "Cel: 160k PLN",
            "bar": 0.89,
            "bar_tone": "primary",
        },
    ],
    "alerts_count": "3 zdarzenia priorytetowe",
    "alerts": [
        {
            "tag": "Krytyczny tachograf",
            "severity": "critical",
            "icon": "timer",
            "title": "Ciągnik WI 4022P",
            "location": "A2 km 384 (Kierunek Poznań)",
            "text": "Zbliżający się limit jazdy ciągłej za !!45 min!!. Najbliższy parking docelowy zapełniony "
            "(zajętość 100%). Ryzyko naruszenia Rozporządzenia 561/2006.",
            "meta": ["Kierowca: Janusz Bogucki", "Pozostało jazdy: 0h 44m"],
            "action": "Przekieruj na MOP Świebodzin",
            "action_icon": "alt_route",
        },
        {
            "tag": "Alert techniczny CAN",
            "severity": "warning",
            "icon": "tire",
            "title": "Naczepa WN 9024X (Krone)",
            "location": "S8 km 112 (koło Piotrkowa Tryb.)",
            "text": "TPMS Oś 2 Koło Lewe: spadek ciśnienia z 8.8 do **6.8 bar** w ciągu 14 min. "
            "Temperatura piasty stabilna (42°C).",
            "meta": ["Ciągnik: WI 1198A", "Prędkość: 84 km/h"],
            "action": "Wezwij serwis mobilny",
            "action_icon": "support",
        },
        {
            "tag": "Cold-chain pharma",
            "severity": "info",
            "icon": "ac_unit",
            "title": "Zestaw Chłodnia #8841 (WZ 7701L)",
            "location": "Trasa: Warszawa → Bruksela",
            "text": "Odchylenie temperatury w komorze pharma: **+1.2°C** (Zadana: +4.0°C, Odczyt CAN: +5.2°C). "
            "Zarejestrowano kod błędu ThermoKing AL-08.",
            "meta": ["Protokół GDP aktywny", "Wartość ładunku: 420 000 EUR"],
            "action": "Zresetuj agregat zdalnie CAN",
            "action_icon": "restart",
        },
    ],
    "corridors_updated": "2 min temu",
    "corridors": [
        {
            "road": "A2",
            "name": "Korytarz Zachodni (Warszawa -> Berlin -> Rotterdam)",
            "status": "Płynny ruch",
            "status_tone": "ok",
            "left": "W trasie: **42 zestawy** TruckMaps",
            "right": "Średnia prędkość handlowa: **82.4 km/h**",
            "note": "1 strefa robót drogowych (km 218) bez zatoru",
            "bar": 0.95,
            "bar_tone": "tertiary",
        },
        {
            "road": "S8 / A4",
            "name": "Korytarz Południowo-Zachodni (Wrocław -> Drezno -> Frankfurt)",
            "status": "Zator +35 min",
            "status_tone": "error",
            "left": "W trasie: **36 zestawów**",
            "right": "!!Kontrola graniczna Jędrzychowice / Görlitz: zator 6 km!!",
            "note": "Alternatywa: trasa przez Zgorzelec Południe",
            "bar": 0.62,
            "bar_tone": "neutral",
        },
        {
            "road": "A1",
            "name": "Korytarz Północ-Południe (Gdańsk Port -> Katowice -> Ostrava)",
            "status": "Optymalne warunki",
            "status_tone": "ok",
            "left": "W trasie: **28 zestawów kontenerowych**",
            "right": "Punktualność slotów terminalowych DCT: **99.1%**",
            "note": "Pogoda: sucho, widoczność bdb",
            "bar": 0.98,
            "bar_tone": "tertiary",
        },
    ],
    "modules": [
        {
            "title": "Symulator 3D Załadunku",
            "icon": "view_in_ar",
            "chip": "EN 12195-1",
            "chip_tone": "tertiary",
            "text": "Rozkład nacisków na osie i pasy mocujące",
            "stats": ["9 planów aktywnych"],
            "link": "Otwórz 3D",
        },
        {
            "title": "Kierowcy i Tachografy",
            "icon": "badge",
            "chip": "312 zalogowanych",
            "text": "Dostępność załóg w promieniu 100 km",
            "stats": ["34 pauza", "18 odpoczynek"],
            "stat_dots": ["primary", "outline"],
            "link": "Szczegóły",
        },
        {
            "title": "Dyspozytornia e-CMR",
            "icon": "receipt",
            "chip": "19 oczekuje",
            "text": "Cyfrowy obieg listów przewozowych",
            "stats": ["142 podpisane cyfrowo dzisiaj"],
            "link": "Zatwierdź",
        },
    ],
    "messages": [
        {
            "tag": "Ostrzeżenie trasy",
            "tone": "error",
            "time": "11:15",
            "title": "Zmasowane kontrole BALM / BAG na A12",
            "text": "Wzmożone kontrole masy całkowitej i mocowania ładunku przed węzłem Frankfurt Oder. Prośba o "
            "przypomnienie kierowcom o dokumentacji kabotażowej.",
            "sender": "Dyspozytor Zmianowy Berlin",
        },
        {
            "tag": "Węzeł centralny",
            "tone": "info",
            "time": "10:48",
            "title": "Baza Stryków (Hub PL-STR-02)",
            "text": "Rampa 14-18 wznowiła przeładunki cross-docking po serwisie bram przemysłowych. Odprawa naczep "
            "typu Mega bez opóźnień.",
            "sender": "Koordynator Magazynu Stryków",
        },
        {
            "tag": "IT / Telemetria",
            "tone": "tertiary",
            "time": "09:30",
            "title": "Aktualizacja oprogramowania telematyki FMS",
            "text": "100% modemów naczep Krone i Schmitz zaktualizowanych zdalnie (OTA). Wszystkie sensory "
            "ciśnienia i temperatury działają poprawnie.",
        },
    ],
}


# Kierowcy pokazowi: (konto, imię i nazwisko).
DRIVERS = [
    ("demo-janusz-bogucki", "Janusz Bogucki"),
    ("demo-pawel-wisniewski", "Paweł Wiśniewski"),
    ("demo-janusz-kowalczyk", "Janusz Kowalczyk"),
]

# Kartoteka modułu Kierowcy (gdy moduł jest zainstalowany): dni od dziś dla terminów.
REGISTER = {
    "demo-janusz-bogucki": {
        "phone": "+48 601 928 344",
        "email": "janusz.bogucki@example.com",
        "hired_on": date(2019, 3, 1),
        "license_categories": ["B", "C", "C+E"],
        "license_until": 384,
        "code95_until": 384,
        "medical_until": 375,
        "psych_until": 375,
        "card_until": 646,
        "card_downloaded_on": -24,
        "card_download_until": 4,
        "adr_until": 600,
        "adr_tank": True,
        "notes": "Preferowane zjazdy na pauzę 45h w Niemczech: Autohof z certyfikatem TAPA TSR1. "
        "Doświadczony na trasach Benelux/Niemcy.",
    },
    "demo-pawel-wisniewski": {
        "phone": "+48 602 118 230",
        "license_categories": ["B", "C", "C+E"],
        "license_until": 900,
        "code95_until": 25,
        "medical_until": 200,
        "psych_until": 200,
        "card_until": 700,
        "card_downloaded_on": -10,
        "card_download_until": 18,
    },
    "demo-janusz-kowalczyk": {
        "phone": "+48 603 554 761",
        "license_categories": ["B", "C", "C+E"],
        "license_until": 1200,
        "code95_until": 500,
        "medical_until": -3,
        "psych_until": 400,
        "card_until": 300,
        "card_downloaded_on": -30,
        "card_download_until": -2,
    },
}

# Ciągnik, naczepa, kierowca (indeks z DRIVERS), czy jedzie, czy w naprawie, terminy (dni od dziś).
FLEET = [
    {
        "tractor": ("Volvo FH 500 I-Save", "WI 4022P", 2023, "euro6"),
        "trailer": ("Schmitz S.CS MEGA", "WN 9024X", 2022, "curtain"),
        "driver": 0,
        "driving": True,
        "inspection": 200,
        "tachograph": 20,
    },
    {
        "tractor": ("Scania 500S Super", "WI 8812M", 2024, "euro6"),
        "trailer": ("Schmitz Chłodnia SKO", "WN 3311A", 2023, "reefer"),
        "driver": 1,
        "inspection": 12,
        "tachograph": 25,
    },
    {
        "tractor": ("Mercedes-Benz Actros 1851", "WI 5543K", 2022, "euro6"),
        "trailer": ("Krone Profi Liner", "WN 7720K", 2021, "curtain"),
        "driver": 2,
        "driving": True,
        "inspection": 10,
        "tachograph": 300,
    },
    {
        "tractor": ("DAF XG+ 480 FT", "WI 1099R", 2023, "euro6"),
        "trailer": ("Wielton Curtain Master", "WN 5544B", 2022, "curtain"),
        "repair": True,
        "inspection": 8,
        "tachograph": 180,
    },
    {
        "tractor": ("MAN TGX 18.510 BLS", "WI 7733T", 2024, "euro6"),
        "trailer": ("Schmitz MEGA Firanka", "WN 2109P", 2024, "curtain"),
        "inspection": 300,
        "tachograph": 400,
        "udt": 60,
    },
]


def _vin(n: int) -> str:
    return f"DEMO{n:013d}"


# Km do następnego serwisu (ciągniki po kolei); DAF – po terminie.
SERVICE_LEFT = [17_150, 42_000, 8_300, -600, 60_000]

# Zlecenia modułu Serwis: ("t", nr ciągnika) albo ("n", nr naczepy) → wpisy:
# (opis, status, wykonane prace, warsztat/mechanik, dni temu, pilność, części [(nazwa, ilość, cena)], godziny, stawka).
SHOP_VOLVO = "Autoryzowany Serwis Volvo Trucks Warszawa"
SERVICE_BOOK = {
    ("t", 0): [
        (
            "Wymiana podwójnego sprzęgła i kalibracja I-Shift",
            "in_progress",
            None,
            "Robert Kowal",
            0,
            "stopped",
            [("Zestaw sprzęgła podwójnego", 1, 9800.0)],
            6.0,
            160.0,
        ),
        (
            "Wymiana filtra osuszacza + serwis A/C",
            "done",
            "Wymiana wkładu osuszacza Wabco, test szczelności układu klimatyzacji",
            SHOP_VOLVO,
            88,
            "can_drive",
            [("Wkład osuszacza Wabco", 1, 410.0), ("Czynnik R134a", 2, 95.0)],
            2.0,
            150.0,
        ),
        (
            "Przegląd zerowy i kalibracja radarów",
            "done",
            "Kalibracja aktywnego tempomatu z I-See oraz asystenta martwego pola",
            SHOP_VOLVO,
            249,
            "can_drive",
            [("Olej silnikowy VDS-5 (l)", 38, 32.0), ("Filtr oleju", 2, 120.0)],
            3.5,
            150.0,
        ),
    ],
    ("t", 1): [
        (
            "TPMS oś 2: spadek ciśnienia lewego koła",
            "new",
            None,
            None,
            0,
            "can_drive",
            [],
            None,
            None,
        ),
        (
            "Wymiana opon osi napędowej",
            "done",
            "4× 315/70 R22.5, wyważenie",
            "Grzegorz Malinowski",
            140,
            "can_drive",
            [("Opona 315/70 R22.5", 4, 1890.0)],
            2.0,
            150.0,
        ),
    ],
    ("t", 2): [
        (
            "Zużycie okładzin hamulcowych <15% oś napędowa",
            "accepted",
            None,
            "Tomasz Bielski",
            0,
            "can_drive",
            [],
            None,
            None,
        ),
        (
            "Wymiana paska wielorowkowego",
            "done",
            "Pasek i napinacz",
            "Tomasz Bielski",
            61,
            "can_drive",
            [("Pasek wielorowkowy", 1, 240.0), ("Napinacz", 1, 680.0)],
            1.5,
            150.0,
        ),
    ],
    ("t", 3): [
        (
            "Wymiana klocków i tarcz hamulcowych",
            "in_progress",
            None,
            "Grzegorz Malinowski",
            1,
            "stopped",
            [("Tarcza hamulcowa 430 mm", 2, 560.0), ("Klocki Jurid 539", 1, 480.0)],
            4.5,
            150.0,
        ),
        (
            "Awaria alternatora",
            "done",
            "Regeneracja alternatora",
            "Warsztat Stryków",
            175,
            "stopped",
            [("Alternator – regeneracja", 1, 1350.0)],
            3.0,
            150.0,
        ),
    ],
    ("t", 4): [
        (
            "Badanie techniczne SKP + dozór UDT windy",
            "new",
            None,
            None,
            0,
            "can_drive",
            [],
            None,
            None,
        ),
    ],
    ("n", 0): [
        (
            "Remont układu hamulcowego i piast",
            "in_progress",
            "Demontaż zacisków hamulcowych, pomiary grubości tarcz: L 41.2 mm, P 40.8 mm (poniżej normy)",
            "Dariusz Wójcik",
            0,
            "stopped",
            [
                ("Tarcza hamulcowa 430 mm", 2, 560.0),
                ("Klocki Jurid 539 Pro", 1, 480.0),
                ("Czujnik zużycia okładzin", 2, 70.0),
            ],
            4.5,
            150.0,
        ),
        (
            "Wymiana poduszki zawieszenia (miech)",
            "done",
            "Oś 1 lewa, Contitech SZ 550",
            "Dariusz Wójcik",
            115,
            "can_drive",
            [("Miech zawieszenia Contitech", 1, 640.0)],
            1.5,
            135.0,
        ),
        (
            "Regeneracja siłownika membranowego",
            "done",
            "Wyciek powietrza na złączu testowym",
            "Warsztat Stryków",
            230,
            "stopped",
            [("Siłownik membranowy", 1, 1150.0)],
            2.0,
            150.0,
        ),
    ],
}


def _service_model():
    """Zlecenia modułu Serwis – `None`, gdy modułu nie ma."""
    try:
        from truckmaps_service.module import ServiceOrder
    except ImportError:
        return None
    return ServiceOrder


def _has(db: Session, model) -> bool:
    return model is not None and db.get_bind().dialect.has_table(
        db.connection(), model.__tablename__
    )


def _seed_trips(db: Session, tractor, trailer, driver: str, i: int) -> None:
    """Przejazdy z ostatnich 26 tygodni (2 w tygodniu): km, koszt tras, kursy puste, postoje."""
    import random

    rnd = random.Random(1000 + i)
    now = datetime.now(UTC)
    rate = 3.9 + 0.12 * i
    for week in range(26):
        for leg in range(2):
            end = now - timedelta(days=7 * week + 3 * leg + 1, hours=rnd.randint(0, 10))
            km = round(rnd.uniform(520, 1350), 1)
            hours = km / rnd.uniform(62, 74)
            db.add(
                VehicleTrip(
                    vehicle_id=tractor.id,
                    trailer_id=trailer.id,
                    driver=driver,
                    started_at=end - timedelta(hours=hours),
                    ended_at=end,
                    distance_km=km,
                    planned_km=round(km * rnd.uniform(0.95, 1.0), 1),
                    cost_amount=round(km * rate, 2),
                    cost_currency="PLN",
                    loaded=rnd.random() > 0.08,
                    idle_min=round(rnd.uniform(10, 70), 0),
                )
            )


def _register_model():
    """Kartoteka modułu Kierowcy – `None`, gdy modułu (albo jego tabeli) nie ma."""
    try:
        from truckmaps_drivers.module import Driver
    except ImportError:
        return None
    return Driver


def remove_fleet(db: Session, company: Company) -> None:
    orders = _service_model()
    if _has(db, orders):
        demo = select(VehicleProfile.id).where(
            VehicleProfile.company_id == company.id, VehicleProfile.vin.like("DEMO%")
        )
        db.execute(delete(orders).where(orders.vehicle_id.in_(demo)))
    demo_ids = select(VehicleProfile.id).where(
        VehicleProfile.company_id == company.id, VehicleProfile.vin.like("DEMO%")
    )
    db.execute(delete(VehicleTrip).where(VehicleTrip.vehicle_id.in_(demo_ids)))
    driver = _register_model()
    if driver is not None and db.get_bind().dialect.has_table(
        db.connection(), driver.__tablename__
    ):
        db.execute(
            delete(driver).where(driver.company_id == company.id, driver.subject.like("demo-%"))
        )
    db.execute(
        delete(VehicleProfile).where(
            VehicleProfile.company_id == company.id, VehicleProfile.vin.like("DEMO%")
        )
    )
    db.execute(
        delete(CompanyMember).where(
            CompanyMember.company_id == company.id, CompanyMember.subject.like("demo-%")
        )
    )


def seed_fleet(db: Session, company: Company) -> None:
    """Tabor ze wzoru Stitch jako zwykłe pojazdy firmy (zastępuje poprzedni tabor pokazowy)."""
    remove_fleet(db, company)
    owner = db.scalar(
        select(CompanyMember.subject).where(
            CompanyMember.company_id == company.id, CompanyMember.role == "owner"
        )
    )
    if owner is None:
        raise SystemExit("Firma bez właściciela")
    for subject, name in DRIVERS:
        db.add(
            CompanyMember(company_id=company.id, subject=subject, display_name=name, role="driver")
        )
    register = _register_model()
    if register is not None and db.get_bind().dialect.has_table(
        db.connection(), register.__tablename__
    ):
        for subject, name in DRIVERS:
            data = dict(REGISTER.get(subject, {}))
            for key, value in data.items():
                if isinstance(value, int) and key.endswith(("_until", "_on")):
                    data[key] = date.today() + timedelta(days=value)
            db.add(register(company_id=company.id, subject=subject, name=name, **data))
    today = date.today()
    now = datetime.now(UTC)
    common = {"owner_subject": owner, "company_id": company.id, "width_m": 2.55, "height_m": 4.0}
    for i, item in enumerate(FLEET):
        t_name, t_plate, t_year, t_euro = item["tractor"]
        r_name, r_plate, r_year, r_type = item["trailer"]
        trailer = VehicleProfile(
            **common,
            kind="semitrailer",
            name=r_name,
            plate=r_plate,
            vin=_vin(100 + i),
            production_year=r_year,
            length_m=13.6,
            weight_t=39.0,
            gvw_t=39.0,
            tare_t=7.5,
            axle_load_t=8.0,
            axle_count=3,
            trailer_type=r_type,
            insurance_until=today + timedelta(days=150),
            ocp_until=today + timedelta(days=150),
            atp_until=today + timedelta(days=90) if r_type == "reefer" else None,
        )
        db.add(trailer)
        db.flush()
        driver = DRIVERS[item["driver"]][0] if "driver" in item else None
        tractor = VehicleProfile(
            **common,
            kind="tractor",
            name=t_name,
            plate=t_plate,
            vin=_vin(i + 1),
            production_year=t_year,
            emission_class=t_euro,
            fuel_type="diesel",
            consumption_loaded=28.0 + i * 0.4,
            consumption_empty=22.0 + i * 0.3,
            length_m=16.5,
            weight_t=40.0,
            gvw_t=40.0,
            tare_t=7.8,
            axle_load_t=11.5,
            axle_count=5,
            trailer_type="none",
            trailer_id=trailer.id,
            assigned_driver=driver,
            in_use_by=driver if item.get("driving") else None,
            in_use_until=now + timedelta(days=365) if item.get("driving") else None,
            in_repair=bool(item.get("repair")),
            odometer_km=142_850 + 37_000 * i,
            service_due_km=142_850 + 37_000 * i + SERVICE_LEFT[i],
            last_inspection=today + timedelta(days=item["inspection"] - 365),
            tachograph_download_until=today + timedelta(days=30 + 7 * i),
            fifth_wheel_m=3.8,
            co2_class=2,
            inspection_until=today + timedelta(days=item["inspection"]),
            tachograph_until=today + timedelta(days=item["tachograph"]),
            udt_until=today + timedelta(days=item["udt"]) if "udt" in item else None,
            insurance_until=today + timedelta(days=150),
            ac_until=today + timedelta(days=150),
            ocp_until=today + timedelta(days=150),
        )
        db.add(tractor)
        db.flush()
        orders = _service_model()
        if _has(db, orders):
            for unit, vehicle in ((("t", i), tractor), (("n", i), trailer)):
                for desc, state, work, shop, ago, urgency, parts, hours, rate in SERVICE_BOOK.get(
                    unit, []
                ):
                    created = now - timedelta(days=ago, hours=3 + i)
                    db.add(
                        orders(
                            vehicle_id=vehicle.id,
                            company_id=company.id,
                            reported_by=driver or owner,
                            reporter_name=dict(DRIVERS).get(driver or "", "Dyspozytor"),
                            description=desc,
                            urgency=urgency,
                            status=state,
                            mechanic_name=shop,
                            work_done=work,
                            parts=[{"name": n, "quantity": q, "price": p} for n, q, p in parts],
                            labour_hours=hours,
                            labour_rate=rate,
                            currency="PLN",
                            odometer_km=vehicle.odometer_km,
                            created_at=created,
                            updated_at=created + timedelta(hours=hours or 1),
                            completed_at=created + timedelta(hours=(hours or 1) + 2)
                            if state == "done"
                            else None,
                        )
                    )
        _seed_trips(db, tractor, trailer, driver or owner, i)


def main(argv: list[str] | None = None, database: Database | None = None) -> None:
    parser = argparse.ArgumentParser(description="Dane pokazowe pulpitu głównego (wzór Stitch)")
    parser.add_argument("--company", help="id albo nazwa firmy")
    parser.add_argument("--remove", action="store_true", help="usuń dane pokazowe")
    parser.add_argument("--list", action="store_true", help="lista firm")
    parser.add_argument(
        "--vehicles", action="store_true", help="tabor pokazowy zamiast treści pulpitu"
    )
    args = parser.parse_args(argv)
    if database is None:
        load_env_file(Path.cwd() / ".env")
        url = Settings.from_env().database_url
        if not url:
            raise SystemExit("Brak DATABASE_URL")
        database = Database(url)
    # Baza deweloperska bez migracji 0042 (np. z migracjami innej gałęzi) – tabela zakładana tu.
    DashboardScreen.__table__.create(database.engine, checkfirst=True)
    with database.session() as db:
        companies = list(db.scalars(select(Company).order_by(Company.created_at)))
        if args.list or not args.company:
            for c in companies:
                print(f"{c.id}  {c.name}")
            if not args.company:
                return
        key = args.company.strip().lower()
        found = [c for c in companies if c.id == args.company or c.name.lower() == key]
        if len(found) != 1:
            raise SystemExit(f"Nie znaleziono jednej firmy: {args.company}")
        company = found[0]
        if args.vehicles:
            (remove_fleet if args.remove else seed_fleet)(db, company)
            db.commit()
            print(("Usunięto" if args.remove else "Zapisano") + f" tabor pokazowy: {company.name}")
            return
        row = db.get(DashboardScreen, company.id)
        if args.remove:
            if row is not None:
                db.delete(row)
        elif row is None:
            db.add(
                DashboardScreen(company_id=company.id, payload=STITCH, updated_at=datetime.now(UTC))
            )
        else:
            row.payload = STITCH
            row.updated_at = datetime.now(UTC)
        db.commit()
        print(("Usunięto" if args.remove else "Zapisano") + f" dane pulpitu: {company.name}")


if __name__ == "__main__":
    main()
