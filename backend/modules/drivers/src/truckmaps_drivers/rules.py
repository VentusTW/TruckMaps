"""Uprawnienia kierowcy: wymagana kategoria prawa jazdy, ADR i terminy (bez bazy danych)."""

from datetime import date

from truckmaps.sdk import DrivingInfo
from truckmaps.sdk.i18n import t

CATEGORIES = ["B", "BE", "C1", "C1E", "C", "CE", "D1", "D1E", "D", "DE"]

IMPLIES = {
    "BE": {"B"},
    "C1": {"B"},
    "C1E": {"C1", "BE", "B"},
    "C": {"C1", "B"},
    "CE": {"C", "C1", "C1E", "BE", "B"},
    "D1": {"B"},
    "D1E": {"D1", "BE", "B"},
    "D": {"D1", "B"},
    "DE": {"D", "D1", "D1E", "BE", "B"},
}
"""Kategoria obejmuje też niższe (dyrektywa 2006/126/WE, art. 6)."""

LIGHT_TRAILER_T = 0.75
"""Przyczepa lekka – bez kategorii „+E”."""
B_LIMIT_T = 3.5
C1_LIMIT_T = 7.5
D1_SEATS = 16

DATE_FIELDS = [
    "license_until",
    "code95_until",
    "medical_until",
    "psych_until",
    "card_until",
    "card_download_until",
    "adr_until",
    "attestation_until",
]
"""Terminy kierowcy „ważne do” – przypomnienia i sprawdzenie przed jazdą."""

SOON_DAYS = {"card_download_until": 7}
"""Ile dni przed terminem ostrzegać (domyślnie 30); pobranie z karty jest co 28 dni."""
DEFAULT_SOON_DAYS = 30
CARD_DOWNLOAD_DAYS = 28


def required_category(info: DrivingInfo) -> str | None:
    """Najniższa kategoria prawa jazdy na ten pojazd z podpiętą naczepą / przyczepą."""
    trailer = info.trailer_gvw_t if info.trailer_kind else None
    heavy_trailer = trailer is not None and trailer > LIGHT_TRAILER_T
    match info.kind:
        case "van":
            if trailer is not None and info.gvw_t + trailer > B_LIMIT_T and heavy_trailer:
                return "BE"
            return "B" if info.gvw_t <= B_LIMIT_T else ("C1" if info.gvw_t <= C1_LIMIT_T else "C")
        case "rigid" | "tractor":
            base = "C1" if info.gvw_t <= C1_LIMIT_T else "C"
            return base + "E" if heavy_trailer else base
        case "combination":
            return "CE"
        case "bus":
            base = "D1" if info.seats is not None and info.seats <= D1_SEATS else "D"
            return base + "E" if heavy_trailer else base
    return None


def covers(categories: list[str], needed: str) -> bool:
    held = set(categories)
    return needed in held or any(needed in IMPLIES.get(c, set()) for c in held)


def professional(category: str | None) -> bool:
    """Kategorie C1, C, D1, D (z „+E”) – kwalifikacja zawodowa (kod 95) i tachograf."""
    return category is not None and category[0] in "CD"


def problems(driver, info: DrivingInfo, today: date) -> list[str]:
    """Co nie pozwala temu kierowcy jechać tym pojazdem (w języku użytkownika)."""
    found = []
    needed = required_category(info)
    categories = list(driver.license_categories or [])
    if needed and not categories:
        found.append(t("drivers.warn_no_categories", need=needed))
    elif needed and not covers(categories, needed):
        found.append(t("drivers.warn_category", need=needed, has=", ".join(categories)))
    if info.hazmat:
        if driver.adr_until is None or driver.adr_until < today:
            found.append(t("drivers.warn_adr"))
        elif info.tanker and not driver.adr_tank:
            found.append(t("drivers.warn_adr_tank"))
    checked = ["license_until", "medical_until", "psych_until", "attestation_until"]
    if professional(needed):
        checked += ["code95_until", "card_until", "card_download_until"]
    for field in checked:
        day = getattr(driver, field)
        if day is not None and day < today:
            found.append(
                t(
                    "drivers.warn_expired",
                    what=t(f"drivers.field.{field}"),
                    day=day.strftime(t("drivers.date_format")),
                )
            )
    return found


def dues(driver, today: date) -> list[tuple[str, date, str]]:
    """Terminy kierowcy: (pole, data, ok | soon | overdue)."""
    result = []
    for field in DATE_FIELDS:
        day = getattr(driver, field)
        if day is None:
            continue
        left = (day - today).days
        soon = SOON_DAYS.get(field, DEFAULT_SOON_DAYS)
        state = "overdue" if left < 0 else "soon" if left <= soon else "ok"
        result.append((field, day, state))
    return result
