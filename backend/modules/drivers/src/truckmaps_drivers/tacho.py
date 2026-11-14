"""Odczyt plików z tachografu cyfrowego (.DDD) – karta kierowcy i tachograf pojazdu (VU).

Format wg załącznika IB i IC do rozporządzenia 3821/85 / 2016/799 (generacja 1 i 2):

* plik karty to ciąg bloków ``FID (2 B) | dodatek (1 B) | długość (2 B) | dane`` – dodatek 0/1
  to dane/podpis generacji 1, 2/3 – generacji 2 (karta G2 zapisuje oba zestawy),
* plik VU zaczyna się od ``0x76`` i numeru odpowiedzi (TREP): 0x01–0x05 generacja 1,
  0x21–0x25 generacja 2, 0x31–0x35 generacja 2 wersja 2 (tablice rekordów z nagłówkiem).

Odczytujemy to, czego potrzeba do ewidencji czasu pracy: dane kierowcy i karty, aktywności
(jazda, praca, dyspozycyjność, odpoczynek) z czasem UTC, miejsca rozpoczęcia i zakończenia
pracy oraz – dla VU – pojazd, okres danych i karty włożone w szczeliny. Podpisów cyfrowych
nie sprawdzamy (do tego potrzebne są certyfikaty ERCA); plik zostaje zapisany w całości.
"""

from dataclasses import dataclass, field
from datetime import UTC, date, datetime, timedelta

ACTIVITIES = ("rest", "available", "work", "driving")
"""Kod aktywności ``aa`` z ActivityChangeInfo: 0 przerwa/odpoczynek … 3 jazda."""

NATIONS = (
    "", "A", "AL", "AND", "ARM", "AZ", "B", "BG", "BIH", "BY", "CH", "CY", "CZ", "D", "DK", "E",
    "EST", "F", "FIN", "FL", "FO", "UK", "GE", "GR", "H", "HR", "I", "IRL", "IS", "KZ", "L", "LT",
    "LV", "M", "MC", "MD", "MK", "N", "NL", "P", "PL", "RO", "RSM", "RUS", "S", "SK", "SLO", "TM",
    "TR", "UA", "V", "YU", "MNE", "SRB", "UZ", "TJ", "KG",
)  # fmt: skip
"""NationNumeric → kod kraju (0xFD WE, 0xFE Europa, 0xFF świat – bez kodu)."""

CARD_IDENTIFICATION = 0x0520
CARD_DOWNLOAD = 0x050E
CARD_ACTIVITY = 0x0504
CARD_PLACES = 0x0506

MAX_DAYS = 400


class TachoError(ValueError):
    """Plik nie jest plikiem z tachografu albo jest uszkodzony (``code`` – klucz tłumaczenia)."""

    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


@dataclass
class Activity:
    start: datetime
    end: datetime
    activity: str
    """driving, work, available, rest albo unknown (karta wyjęta, brak wpisu ręcznego)."""
    card_number: str = ""
    holder_name: str = ""
    slot: int = 0
    """0 – kierowca, 1 – drugi kierowca."""
    crew: bool = False
    manual: bool = False

    @property
    def minutes(self) -> int:
        return int((self.end - self.start).total_seconds() // 60)


@dataclass
class Place:
    at: datetime
    entry: str
    """begin albo end (dzień pracy); ręczne wpisy też tak oznaczone."""
    country: str
    region: int
    odometer: int
    lat: float | None = None
    lon: float | None = None
    card_number: str = ""


@dataclass
class TachoFile:
    kind: str
    """card albo vu."""
    generation: int
    card_number: str = ""
    holder_name: str = ""
    birth_date: date | None = None
    card_expiry: date | None = None
    nation: str = ""
    downloaded_at: datetime | None = None
    vin: str = ""
    plate: str = ""
    period_start: datetime | None = None
    period_end: datetime | None = None
    activities: list[Activity] = field(default_factory=list)
    places: list[Place] = field(default_factory=list)

    def cards(self) -> dict[str, str]:
        """Karty w danych (numer → posiadacz) – dla VU wszyscy kierowcy, dla karty jeden."""
        found = {a.card_number: a.holder_name for a in self.activities if a.card_number}
        if self.card_number:
            found[self.card_number] = self.holder_name
        return found


# ── Pola podstawowe ───────────────────────────────────────────────────────────────────────────


def _u(data: bytes, pos: int, size: int) -> int:
    if pos + size > len(data):
        raise TachoError("tacho.truncated")
    return int.from_bytes(data[pos : pos + size], "big")


def _time(data: bytes, pos: int) -> datetime | None:
    """TimeReal – sekundy od 1970-01-01 UTC (0 i 0xFFFFFFFF – brak)."""
    value = _u(data, pos, 4)
    if value in (0, 0xFFFFFFFF):
        return None
    return datetime.fromtimestamp(value, UTC)


def _text(raw: bytes) -> str:
    return raw.decode("latin-1").replace("\x00", " ").replace("\xff", " ").strip()


def _name(raw: bytes) -> str:
    """Name – strona kodowa (1 B) i tekst; strony 1–16 to ISO 8859-n."""
    page, text = raw[0], raw[1:]
    try:
        decoded = text.decode(f"iso8859_{page}") if 1 <= page <= 16 and page != 12 else _text(text)
    except (LookupError, UnicodeDecodeError):
        decoded = _text(text)
    return decoded.replace("\x00", " ").strip()


def _holder(raw: bytes) -> str:
    """HolderName – nazwisko (36 B) i imiona (36 B)."""
    return " ".join(p for p in (_name(raw[36:72]), _name(raw[:36])) if p)


def _bcd_date(raw: bytes) -> date | None:
    """Datef – rok (2 B) miesiąc i dzień w BCD."""
    digits = raw.hex()
    try:
        return date(int(digits[:4]), int(digits[4:6]), int(digits[6:8]))
    except ValueError:
        return None


def _nation(code: int) -> str:
    return NATIONS[code] if code < len(NATIONS) else ""


def _coordinate(raw: bytes) -> float | None:
    """GeoCoordinates (G2) – ±DDMM.M w dziesiątych minuty, 3 B ze znakiem."""
    value = int.from_bytes(raw, "big", signed=True)
    if value in (0x7FFFFF, -0x800000):
        return None
    degrees, tenths = divmod(abs(value), 1000)
    result = degrees + tenths / 600
    return round(-result if value < 0 else result, 5)


def _change(word: int) -> tuple[int, bool, bool, str, int]:
    """ActivityChangeInfo ``scpaattttttttttt`` → szczelina, załoga, wpis ręczny, aktywność,
    minuta doby."""
    slot = word >> 15 & 1
    crew_or_known = bool(word >> 14 & 1)
    absent = bool(word >> 13 & 1)
    activity = ACTIVITIES[word >> 11 & 3]
    minute = word & 0x7FF
    if absent:
        # Karta wyjęta: c=1 – aktywność wpisana ręcznie, c=0 – nieznana.
        return slot, False, crew_or_known, activity if crew_or_known else "unknown", minute
    return slot, crew_or_known, False, activity, minute


def _day_segments(day: datetime, words: list[int]) -> list[tuple[int, Activity]]:
    """Aktywności jednej doby (zmiany w kolejności zapisu) – (szczelina, odcinek)."""
    changes = [_change(w) for w in words]
    result = []
    for slot in {c[0] for c in changes}:
        mine = [c for c in changes if c[0] == slot and c[4] < 1440]
        for i, (_, crew, manual, activity, minute) in enumerate(mine):
            end = mine[i + 1][4] if i + 1 < len(mine) else 1440
            if end <= minute:
                continue
            result.append(
                (
                    slot,
                    Activity(
                        start=day + timedelta(minutes=minute),
                        end=day + timedelta(minutes=end),
                        activity=activity, slot=slot, crew=crew, manual=manual,
                    ),
                )
            )  # fmt: skip
    return result


def merge(items: list[Activity]) -> list[Activity]:
    """Łączy przylegające odcinki tej samej aktywności (np. odpoczynek przez północ)."""
    items = sorted(items, key=lambda a: (a.card_number, a.slot, a.start))
    result: list[Activity] = []
    for item in items:
        last = result[-1] if result else None
        if (
            last is not None
            and last.end == item.start
            and (last.activity, last.card_number, last.slot, last.crew, last.manual)
            == (item.activity, item.card_number, item.slot, item.crew, item.manual)
        ):
            last.end = item.end
        else:
            result.append(item)
    result.sort(key=lambda a: a.start)
    return result


# ── Karta kierowcy ────────────────────────────────────────────────────────────────────────────


def _blocks(data: bytes) -> dict[tuple[int, int], bytes]:
    """Bloki pliku karty: (FID, generacja) → dane (podpisy pomijamy)."""
    found: dict[tuple[int, int], bytes] = {}
    pos = 0
    while pos + 5 <= len(data):
        fid, appendix, size = _u(data, pos, 2), data[pos + 2], _u(data, pos + 3, 2)
        pos += 5
        if pos + size > len(data) or appendix > 3:
            raise TachoError("tacho.truncated")
        if appendix in (0, 2):
            found[(fid, 2 if appendix == 2 else 1)] = data[pos : pos + size]
        pos += size
    return found


def _card_activities(value: bytes) -> list[Activity]:
    """CardDriverActivity: wskaźniki najstarszego i najnowszego rekordu, bufor cykliczny
    rekordów dziennych (długość poprzedniego, długość, data, licznik, dystans, zmiany)."""
    if len(value) < 16:
        return []
    oldest, newest = _u(value, 0, 2), _u(value, 2, 2)
    buffer = value[4:]
    size = len(buffer)
    if newest >= size or oldest >= size:
        raise TachoError("tacho.truncated")

    def read(pos: int, count: int) -> bytes:
        return bytes(buffer[(pos + i) % size] for i in range(count))

    result: list[Activity] = []
    pos = newest
    for _ in range(MAX_DAYS):
        header = read(pos, 12)
        previous, length = _u(header, 0, 2), _u(header, 2, 2)
        if length < 12 or length > size:
            break
        day = _time(header, 4)
        if day is not None:
            body = read(pos + 12, length - 12)
            words = [_u(body, i, 2) for i in range(0, len(body) - 1, 2)]
            result.extend(s for _, s in _day_segments(day, words))
        if pos == oldest or previous == 0:
            break
        pos = (pos - previous) % size
    return result


def _card_places(value: bytes, generation: int) -> list[Place]:
    pointer = 2 if generation == 2 else 1
    size = 21 if generation == 2 else 10
    result = []
    for pos in range(pointer, len(value) - size + 1, size):
        at = _time(value, pos)
        if at is None:
            continue
        kind = value[pos + 4]
        lat = lon = None
        if generation == 2:
            lat, lon = (
                _coordinate(value[pos + 15 : pos + 18]),
                _coordinate(value[pos + 18 : pos + 21]),
            )
        result.append(
            Place(
                at=at, entry="begin" if kind in (0, 2) else "end",
                country=_nation(value[pos + 5]), region=value[pos + 6],
                odometer=_u(value, pos + 7, 3), lat=lat, lon=lon,
            )
        )  # fmt: skip
    result.sort(key=lambda p: p.at)
    return result


def parse_card(data: bytes) -> TachoFile:
    blocks = _blocks(data)
    generation = 2 if any(g == 2 for _, g in blocks) else 1

    def best(fid: int) -> tuple[bytes | None, int]:
        for gen in (2, 1):
            if (fid, gen) in blocks:
                return blocks[(fid, gen)], gen
        return None, generation

    ident, _ = best(CARD_IDENTIFICATION)
    activity, _ = best(CARD_ACTIVITY)
    if ident is None or len(ident) < 143 or activity is None:
        raise TachoError("tacho.not_card")
    expiry = _time(ident, 61)
    result = TachoFile(
        kind="card",
        generation=generation,
        nation=_nation(ident[0]),
        card_number=_text(ident[1:17]),
        card_expiry=expiry.date() if expiry else None,
        holder_name=" ".join(p for p in (_name(ident[101:137]), _name(ident[65:101])) if p),
        birth_date=_bcd_date(ident[137:141]),
    )
    download, _ = best(CARD_DOWNLOAD)
    if download is not None and len(download) >= 4:
        result.downloaded_at = _time(download, 0)
    for item in _card_activities(activity):
        item.card_number, item.holder_name = result.card_number, result.holder_name
        result.activities.append(item)
    result.activities = merge(result.activities)
    places, gen = best(CARD_PLACES)
    if places is not None:
        result.places = _card_places(places, gen)
        for place in result.places:
            place.card_number = result.card_number
    if result.activities:
        result.period_start = result.activities[0].start
        result.period_end = max(a.end for a in result.activities)
    return result


# ── Tachograf pojazdu (VU) ────────────────────────────────────────────────────────────────────


@dataclass
class _Insertion:
    card_number: str
    holder_name: str
    slot: int
    inserted: datetime | None
    withdrawn: datetime | None


def _insertion(raw: bytes) -> _Insertion:
    """VuCardIWRecord: nazwisko i imiona (72), numer karty (18; G2 +1 B generacji), ważność,
    włożenie, licznik, szczelina, wyjęcie…"""
    offset = 72 + (19 if len(raw) > 129 else 18)
    return _Insertion(
        card_number=_text(raw[74:90]),
        holder_name=_holder(raw[:72]),
        inserted=_time(raw, offset + 4),
        slot=raw[offset + 11],
        withdrawn=_time(raw, offset + 12),
    )


def _attribute(day: datetime, words: list[int], cards: list[_Insertion]) -> list[Activity]:
    """Aktywności doby VU przypisane do kart w szczelinach (bez karty – pomijane)."""
    result = []
    for slot, item in _day_segments(day, words):
        if item.activity == "unknown":
            continue
        middle = item.start + (item.end - item.start) / 2
        for card in cards:
            if (
                card.slot == slot
                and (card.inserted is None or card.inserted <= middle)
                and (card.withdrawn is None or middle < card.withdrawn)
            ):
                item.card_number, item.holder_name = card.card_number, card.holder_name
                result.append(item)
                break
    return result


def _vu_places(raw: bytes, card_size: int) -> Place | None:
    """VuPlaceDailyWorkPeriodRecord: numer karty i PlaceRecord (G1 10 B, G2 21 B)."""
    pos = card_size
    at = _time(raw, pos)
    if at is None:
        return None
    lat = lon = None
    if len(raw) >= pos + 21:
        lat, lon = _coordinate(raw[pos + 15 : pos + 18]), _coordinate(raw[pos + 18 : pos + 21])
    return Place(
        at=at, entry="begin" if raw[pos + 4] in (0, 2) else "end", country=_nation(raw[pos + 5]),
        region=raw[pos + 6], odometer=_u(raw, pos + 7, 3), lat=lat, lon=lon,
        card_number=_text(raw[2:18]),
    )  # fmt: skip


def _parse_vu_gen1(data: bytes, result: TachoFile) -> None:
    pos = 0
    while pos + 2 <= len(data) and data[pos] == 0x76:
        trep = data[pos + 1]
        pos += 2
        if trep == 0x01:
            pos += 2 * 194
            result.vin = _text(data[pos : pos + 17])
            result.plate = _name(data[pos + 18 : pos + 32])
            pos += 17 + 15
            result.downloaded_at = _time(data, pos)
            result.period_start, result.period_end = _time(data, pos + 4), _time(data, pos + 8)
            pos += 4 + 8 + 1 + 58
            pos += 1 + 98 * _u(data, pos, 1)
            pos += 1 + 31 * _u(data, pos, 1)
            pos += 128
        elif trep == 0x02:
            day = _time(data, pos)
            pos += 4 + 3
            count = _u(data, pos, 2)
            pos += 2
            cards = [_insertion(data[pos + i * 129 : pos + (i + 1) * 129]) for i in range(count)]
            pos += 129 * count
            count = _u(data, pos, 2)
            pos += 2
            words = [_u(data, pos + 2 * i, 2) for i in range(count)]
            pos += 2 * count
            count = _u(data, pos, 1)
            pos += 1
            for i in range(count):
                place = _vu_places(data[pos + 28 * i : pos + 28 * (i + 1)], 18)
                if place is not None:
                    result.places.append(place)
            pos += 28 * count
            pos += 2 + 5 * _u(data, pos, 2) + 128
            if pos > len(data):
                raise TachoError("tacho.truncated")
            if day is not None:
                result.activities.extend(_attribute(day, words, cards))
        else:
            # Zdarzenia, prędkość, dane techniczne – niepotrzebne do czasu pracy.
            break


def _parse_vu_gen2(data: bytes, result: TachoFile) -> None:
    pos = 0
    while pos + 2 <= len(data) and data[pos] == 0x76:
        trep = data[pos + 1] & 0x0F
        pos += 2
        arrays: list[tuple[int, list[bytes]]] = []
        while True:
            kind, size, count = _u(data, pos, 1), _u(data, pos + 1, 2), _u(data, pos + 3, 2)
            pos += 5
            if pos + size * count > len(data):
                raise TachoError("tacho.truncated")
            arrays.append(
                (kind, [data[pos + i * size : pos + (i + 1) * size] for i in range(count)])
            )
            pos += size * count
            if kind == 0x08:  # tablica podpisów zamyka odpowiedź
                break
        if trep == 0x01:
            for kind, records in arrays:
                if not records:
                    continue
                first = records[0]
                if kind == 0x0A:
                    result.vin = _text(first)
                elif kind == 0x0B:
                    result.plate = _name(first)
                elif kind == 0x24:
                    result.plate = _name(first[1:])
                elif kind == 0x03:
                    result.downloaded_at = _time(first, 0)
                elif kind == 0x13:
                    result.period_start, result.period_end = _time(first, 0), _time(first, 4)
        elif trep == 0x02:
            day, cards, words = None, [], []
            for kind, records in arrays:
                if kind == 0x06 and records:
                    day = _time(records[0], 0)
                elif kind == 0x0D:
                    cards = [_insertion(r) for r in records]
                elif kind == 0x01:
                    words = [_u(r, 0, 2) for r in records]
                elif kind == 0x1C:
                    for record in records:
                        place = _vu_places(record, 19)
                        if place is not None:
                            result.places.append(place)
            if day is not None:
                result.activities.extend(_attribute(day, words, cards))


def parse_vu(data: bytes) -> TachoFile:
    second = data[1] if len(data) > 1 else 0
    generation = 1 if second <= 0x05 else 2
    result = TachoFile(kind="vu", generation=generation)
    if generation == 1:
        _parse_vu_gen1(data, result)
    else:
        _parse_vu_gen2(data, result)
    result.activities = merge(result.activities)
    result.places.sort(key=lambda p: p.at)
    if not result.vin and not result.activities:
        raise TachoError("tacho.not_vu")
    if result.activities and result.period_start is None:
        result.period_start = result.activities[0].start
        result.period_end = max(a.end for a in result.activities)
    return result


def parse(data: bytes) -> TachoFile:
    """Plik .DDD karty kierowcy albo tachografu pojazdu."""
    if len(data) < 8:
        raise TachoError("tacho.not_ddd")
    if data[0] == 0x76 and (data[1] <= 0x05 or 0x21 <= data[1] <= 0x25 or 0x31 <= data[1] <= 0x35):
        return parse_vu(data)
    if data[:3] in (b"\x00\x02\x00", b"\x00\x02\x02") or data[:2] in (b"\x05\x01", b"\x05\x20"):
        return parse_card(data)
    raise TachoError("tacho.not_ddd")
