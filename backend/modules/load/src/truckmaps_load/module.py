"""Plan załadunku (M12): LDM, masa, naciski na osie, rozmieszczenie palet i mocowanie.

Palety układamy rzędami od ściany czołowej; ładunek ostatniego rozładunku idzie na przód,
pierwszego – przy drzwiach. W rzędzie wybieramy ułożenie, które zajmuje najmniej długości
(np. palety EUR 3 wzdłuż w rzędzie 1,2 m – 33 na 13,6 m; przemysłowe 2 w poprzek w rzędzie
1,0 m – 26).

Naciski: przestrzeń ładunkowa jako belka na dwóch podporach (siodło i zespół osi naczepy,
oś przednia i tylna solówki…), z masą własną rozłożoną typowo. Gdy ułożenie od ściany
czołowej przeciąża podporę, plan przestawia rzędy w obrębie rozładunku (cięższe bliżej
środka ciężkości osi) albo odsuwa ładunek od ściany – wybiera ułożenie bez przekroczeń,
najbliżej ściany czołowej. Ręczne ułożenie (przeciągnięte palety) sprawdza ``/plan/check``.

Mocowanie: liczba pasów przy mocowaniu przez docisk (top-over) wg uproszczonego wzoru
EN 12195-1. To pomoc, nie certyfikat – za rozmieszczenie i zabezpieczenie ładunku
odpowiadają ładujący i kierowca.
"""

import json
import math
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from importlib import resources
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import JSON, DateTime, String, select
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column

from truckmaps.sdk import CoreContext, Module, Principal, i18n
from truckmaps.sdk.fleet import BODY_GROUP, BODY_GROUPS, CargoInfo
from truckmaps.sdk.i18n import t
from truckmaps_load import report
from truckmaps_load.cargo import (
    BUILT_IN,
    CATALOG,
    DECK,
    GROUPS,
    CargoType,
    Gear,
    Securing,
    Shape,
    for_kind,
)
from truckmaps_load.securing import (
    AIRBAG_GAP_M,
    CHAIN_DAN,
    DRIVE_MIN_SHARE,
    LASHINGS_PER_PIECE,
    MAX_STRAPS_PER_M,
    STEER_AXLE_KG,
    TRACTOR_TARE_KG,
    TYPICAL_TRACTOR_KG,
    BodyCode,
    Equipment,
    Forces,
    Norm,
    Tractor,
    direct_lc_daN,
    equipment,
    forces,
    friction,
    row_tension_daN,
    straps_for,
    tractor,
    tractor_problems,
    wall_capacity_kN,
    wall_holds,
)

LDM_WIDTH_M = 2.4
"""Metr ładowny: 1 m długości przestrzeni o szerokości 2,4 m."""
EUR = (1.2, 0.8)
"""Miejsce paletowe (paleta EUR) – do liczenia miejsc na podłodze."""
# Rozsądny środek ciężkości ładunku (część długości od ściany czołowej) – gdy naciski nieznane.
COG_MIN, COG_MAX = 0.35, 0.6

PALLETS = {"euro": (1.2, 0.8), "industrial": (1.2, 1.0), "half": (0.8, 0.6)}
# Typowa przestrzeń ładunkowa, gdy pojazd nie ma jej w profilu: (długość, szerokość) [m].
DECKS = {"semitrailer": (13.6, 2.48), "combination": (13.6, 2.48)}
# Wysokość podłogi nad jezdnią – przestrzeń ładunkowa = wysokość pojazdu − podłoga − dach.
FLOOR_M = {"semitrailer": 1.2, "combination": 1.2, "trailer": 1.1, "rigid": 1.1, "van": 0.6}
ROOF_M = 0.1
# Wysokość sztuki do widoku z boku, gdy jej nie podano (paleta z towarem).
DEFAULT_HEIGHT_M = 1.2
KINGPIN_LIMIT_KG = 12_000
"""Typowy dopuszczalny nacisk siodła ciągnika – gdy nie znamy ciągnika."""
# Dopuszczalny nacisk zespołu osi (dyrektywa 96/53/WE, rozstaw 1,3–1,8 m).
GROUP_LIMIT_KG = {1: 10_000, 2: 18_000, 3: 24_000}
TYPICAL_KINGPIN_M = 1.6
"""Sworzeń od ściany czołowej naczepy, gdy brak go w profilu."""
RIGID_FRONT_AXLE_M = -1.2
"""Oś przednia solówki względem początku skrzyni (przed nią – kabina)."""
STEP_M = 0.05
"""Krok przesuwania ładunku przy szukaniu ułożenia bez przekroczeń."""


class Base(DeclarativeBase):
    pass


class CustomCargo(Base):
    """Własny rodzaj towaru użytkownika."""

    __tablename__ = "load_cargo_types"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    owner: Mapped[str] = mapped_column(String(255), index=True)
    data: Mapped[dict] = mapped_column(JSON)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


GEAR_IDS = ("straps", "edges", "beams", "mats", "airbags", "chains", "chocks", "net", "stakes")
"""Sprzęt z listy VDI 2700 – także wyposażenie użytkownika."""


class OwnEquipment(Base):
    """Wyposażenie użytkownika (ile sztuk sprzętu do mocowania ma w pojeździe)."""

    __tablename__ = "load_equipment"

    owner: Mapped[str] = mapped_column(String(255), primary_key=True)
    data: Mapped[dict] = mapped_column(JSON)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class EquipmentIn(BaseModel):
    items: dict[str, int] = Field(default_factory=dict)
    """Ile sztuk ma użytkownik (``GEAR_IDS``)."""
    enabled: bool = True
    """Uwzględniać w planie."""

    @field_validator("items")
    @classmethod
    def _known(cls, value: dict[str, int]) -> dict[str, int]:
        if any(k not in GEAR_IDS or not 0 <= v <= 1000 for k, v in value.items()):
            raise ValueError("unknown equipment")
        return value


class Item(BaseModel):
    kind: Literal["euro", "industrial", "half", "custom"] = "euro"
    cargo: str | None = Field(default=None, max_length=40, description="Rodzaj towaru (katalog)")
    length_m: float | None = Field(default=None, gt=0, le=14, description="Tylko „custom”")
    width_m: float | None = Field(default=None, gt=0, le=2.6, description="Tylko „custom”")
    height_m: float | None = Field(default=None, gt=0, le=3.5, description="Wysokość sztuki")
    count: int = Field(ge=1, le=100)
    weight_kg: float = Field(gt=0, le=30_000, description="Masa jednej sztuki")
    stack: int = Field(default=1, ge=1, le=10, description="Ile sztuk w stosie")
    stop: int = Field(default=1, ge=1, le=20, description="Numer rozładunku (1 – pierwszy)")
    label: str = Field(default="", max_length=60)


class PlanIn(BaseModel):
    vehicle_id: str
    items: list[Item] = Field(min_length=1, max_length=30)
    deck_length_m: float | None = Field(default=None, gt=1, le=20)
    deck_width_m: float | None = Field(default=None, gt=1, le=2.6)
    front_wall: bool = Field(default=True, description="Ładunek oparty o ścianę czołową")
    mats: bool = Field(default=False, description="Maty antypoślizgowe pod paletami")
    strap_daN: int = Field(default=400, ge=100, le=1000, description="Siła napięcia pasa STF")
    body_code: BodyCode = Field(
        default="unknown",
        description="Kod nadwozia EN 12642 (ściana czołowa); „unknown” – nie wiadomo",
    )
    reference: str = Field(default="", max_length=40, description="Numer zlecenia")
    available: dict[str, int] | None = Field(
        default=None, description="Sprzęt użytkownika; ``None`` – bez ograniczeń"
    )

    @field_validator("available")
    @classmethod
    def _known_gear(cls, value: dict[str, int] | None) -> dict[str, int] | None:
        if value is not None and any(k not in GEAR_IDS or v < 0 for k, v in value.items()):
            raise ValueError("unknown equipment")
        return value


class Placed(BaseModel):
    item: int
    """Numer pozycji w ``items``."""
    x_m: float
    """Odległość od ściany czołowej (przód palety)."""
    y_m: float
    """Odległość od lewej burty."""
    length_m: float
    width_m: float
    weight_kg: float
    stop: int
    pieces: int = 1
    """Sztuk w stosie."""
    height_m: float = DEFAULT_HEIGHT_M
    """Wysokość stosu."""
    height_known: bool = False
    """``False`` – wysokość szacunkowa (sztuki bez podanej wysokości)."""


class CheckIn(PlanIn):
    placed: list[Placed] = Field(min_length=1, max_length=400)


class ExportIn(PlanIn):
    placed: list[Placed] | None = Field(default=None, max_length=400)
    """Ułożenie z ekranu (przeciągnięte); ``None`` – plan liczony od nowa."""
    checked: list[str] = Field(default=[], max_length=10)
    """Sprzęt potwierdzony na liście kontrolnej."""
    approved: bool = False


class Row(BaseModel):
    x_m: float
    length_m: float
    weight_kg: float
    straps: int
    method: str = "top"
    """Mocowanie rzędu: ``top`` (pasy dociskowe), ``direct``, ``none``, ``mixed``."""
    lashings: int = 0
    """Odciągi mocowania bezpośredniego w rzędzie."""


class Axle(BaseModel):
    name: Literal["kingpin", "trailer_axles", "front_axle", "rear_axles", "drawbar_front"]
    x_m: float
    """Położenie od ściany czołowej (oś przednia solówki – przed przestrzenią: wartość ujemna)."""
    load_kg: float
    """Nacisk z masą własną i ładunkiem."""
    limit_kg: float | None
    over: bool


class PlanOut(BaseModel):
    deck_length_m: float
    deck_width_m: float
    inner_height_m: float | None
    ldm: float
    used_length_m: float
    weight_kg: float
    payload_kg: float | None
    """Ładowność z profilu (DMC − masa własna); ``None`` – brak danych."""
    fits: bool
    placed: list[Placed]
    unplaced: int
    """Sztuki, które się nie zmieściły."""
    rows: list[Row]
    straps: int
    cog_m: float | None
    """Środek ciężkości ładunku od ściany czołowej."""
    axles: list[Axle]
    """Naciski na podpory (puste, gdy nie znamy pojazdu)."""
    offset_m: float
    """Odstęp ładunku od ściany czołowej."""
    adjusted: bool
    """Plan przestawił ładunek, żeby nie przekroczyć nacisków."""
    warnings: list[str]
    body_code: BodyCode = "unknown"
    reference: str = ""
    pallet_places: int = 0
    """Miejsca paletowe EUR na podłodze."""
    places_used: int = 0
    """Zajęta podłoga w miejscach paletowych EUR."""
    forces: Forces | None = None
    tractor: Tractor | None = None
    """Ciągnik siodłowy (naczepa / zestaw) – typowa geometria."""
    equipment: list[Equipment] = []
    norms: list[Norm] = []
    mats: bool = False
    """Plan liczony z matami antypoślizgowymi (wybór użytkownika albo propozycja)."""
    shortages: dict[str, int] = {}
    """Brakujący sprzęt względem wyposażenia użytkownika (ile sztuk brakuje)."""
    estimated: Literal[True] = True


@dataclass(frozen=True)
class Support:
    name: str
    x: float
    limit: float | None
    tare: float
    """Część masy własnej przypadająca na tę podporę [kg]."""


def supports(cargo: CargoInfo | None, deck_length: float) -> list[Support]:
    """Dwie podpory przestrzeni ładunkowej (typowa geometria pojazdu)."""
    if cargo is None or not cargo.kind or cargo.axle_count is None:
        return []
    axle_kg = (cargo.axle_load_t or 0) * 1000 or None

    def group(count: int) -> float | None:
        legal = GROUP_LIMIT_KG.get(count, 24_000)
        return min(legal, axle_kg * count) if axle_kg else legal

    tare = cargo.tare_kg
    if cargo.kind in ("semitrailer", "combination"):
        axles = cargo.axle_count if cargo.kind == "semitrailer" else max(1, cargo.axle_count - 2)
        trailer_tare = tare if cargo.kind == "semitrailer" else (
            max(0.0, tare - TRACTOR_TARE_KG) if tare is not None else None
        )  # fmt: skip
        trailer_tare = trailer_tare if trailer_tare is not None else 7000.0
        # Z dokumentów naczepy (sworzeń, środek osi), inaczej typowa geometria.
        kingpin = cargo.kingpin_m or TYPICAL_KINGPIN_M
        axle_x = cargo.axles_m or round(deck_length * 0.7, 2)
        return [
            Support("kingpin", kingpin, KINGPIN_LIMIT_KG, trailer_tare * 0.35),
            Support("trailer_axles", axle_x, group(axles), trailer_tare * 0.65),
        ]
    if cargo.kind == "rigid":
        rear = max(1, cargo.axle_count - 1)
        own = tare if tare is not None else 0.0
        return [
            Support(
                "front_axle",
                RIGID_FRONT_AXLE_M,
                min(STEER_AXLE_KG, axle_kg or STEER_AXLE_KG),
                own * 0.6,
            ),
            Support(
                "rear_axles",
                round(cargo.wheelbase_m + RIGID_FRONT_AXLE_M, 2)
                if cargo.wheelbase_m
                else round(deck_length * 0.55, 2),
                group(rear),
                own * 0.4,
            ),
        ]
    if cargo.kind == "trailer":
        front = max(1, cargo.axle_count // 2)
        rear = max(1, cargo.axle_count - front)
        own = tare if tare is not None else 0.0
        return [
            Support("drawbar_front", round(deck_length * 0.15, 2), group(front), own * 0.5),
            Support("rear_axles", round(deck_length * 0.85, 2), group(rear), own * 0.5),
        ]  # fmt: skip
    return []


def axle_loads(placed: list[Placed], points: list[Support]) -> list[Axle]:
    if len(points) != 2:
        return []
    a, b = points
    rear = sum(p.weight_kg * (p.x_m + p.length_m / 2 - a.x) / (b.x - a.x) for p in placed)
    front = sum(p.weight_kg for p in placed) - rear
    return [
        Axle(
            name=s.name, x_m=s.x, load_kg=round(s.tare + load), limit_kg=s.limit,
            over=s.limit is not None and s.tare + load > s.limit + 0.5,
        )
        for s, load in ((a, front), (b, rear))
    ]  # fmt: skip


def _overload(axles: list[Axle]) -> float:
    return sum(max(0.0, a.load_kg - a.limit_kg) for a in axles if a.limit_kg is not None)


Types = list[CargoType | None]
"""Rodzaj towaru każdej pozycji (``None`` – nieznany: paleta / sztuka ogólna)."""


def item_types(data: PlanIn, custom: dict[str, CargoType] | None = None) -> Types:
    """Rodzaje towaru pozycji: z katalogu, własne użytkownika albo wg rodzaju palety."""
    found = {**BUILT_IN, **(custom or {})}
    return [found.get(i.cargo or "") or for_kind(i.kind) for i in data.items]


def cargo_name(c: CargoType) -> str:
    return c.name if c.custom else t(f"load.cargo.{c.id}")


def _footprint(item: Item, ctype: CargoType | None = None) -> tuple[float, float]:
    if item.kind == "custom":
        length = item.length_m or (ctype.length_m if ctype else None)
        width = item.width_m or (ctype.width_m if ctype else None)
        if length is None or width is None:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, t("load.custom_size"))
        return length, width
    return PALLETS[item.kind]


def _row_layout(length: float, width: float, deck_width: float) -> tuple[float, float, int]:
    """Najkrótszy rząd na 1 m: (długość rzędu, szerokość sztuki w poprzek, sztuk w rzędzie)."""
    options = []
    for along, across in ((length, width), (width, length)):
        per_row = int(deck_width // across + 1e-9)
        if per_row:
            options.append((along / per_row, along, across, per_row))
    if not options:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, t("load.too_wide"))
    _, along, across, per_row = min(options)
    return along, across, per_row


def _too_heavy_row(
    item: Item, ctype: CargoType | None, per_row: int, along: float, data: PlanIn
) -> bool:
    """Pełny rząd tej pozycji wymaga więcej pasów dociskowych, niż da się założyć."""
    if ctype is not None and ctype.securing != "top":
        return False
    mu = ctype.mu if ctype else friction(False)
    mu = max(mu, friction(True)) if data.mats else mu
    weight = per_row * item.stack * item.weight_kg
    straps = straps_for(row_tension_daN(weight, mu, forward=not data.front_wall), data.strap_daN)
    return straps > max(1, math.floor(along * MAX_STRAPS_PER_M))


@dataclass
class _Row:
    stop: int
    length: float
    pieces: list[Placed]
    """Sztuki rzędu z ``x_m`` = 0."""

    @property
    def weight(self) -> float:
        return sum(p.weight_kg for p in self.pieces)


def _rows(
    data: PlanIn, deck_width: float, types: Types | None = None, narrow: bool = False
) -> list[_Row]:
    """Rzędy po kolei od przodu: ostatni rozładunek pierwszy. ``narrow`` – o jedną sztukę mniej
    w rzędzie tam, gdzie pełnego rzędu nie da się zamocować pasami (kosztem długości)."""
    types = types if types is not None else item_types(data)
    order = sorted(range(len(data.items)), key=lambda i: -data.items[i].stop)
    rows: list[_Row] = []
    for index in order:
        item = data.items[index]
        ctype = types[index]
        length, width = _footprint(item, ctype)
        along, across, per_row = _row_layout(length, width, deck_width)
        if narrow and per_row > 1 and _too_heavy_row(item, ctype, per_row, along, data):
            per_row -= 1
        stacks = math.ceil(item.count / item.stack)
        piece_m = item.height_m or (
            ctype.height_m if ctype and ctype.kind == "custom" else DEFAULT_HEIGHT_M
        )
        left = item.count
        for start in range(0, stacks, per_row):
            pieces = []
            for k in range(min(per_row, stacks - start)):
                count = min(item.stack, left)
                left -= count
                pieces.append(
                    Placed(
                        item=index, x_m=0, y_m=round(k * across, 3), length_m=along,
                        width_m=across, weight_kg=count * item.weight_kg, stop=item.stop,
                        pieces=count, height_m=round(count * piece_m, 2),
                        height_known=item.height_m is not None,
                    )
                )  # fmt: skip
            rows.append(_Row(item.stop, along, pieces))
    return rows


def _lay(
    rows: list[_Row], offset: float, deck_length: float, gap_at: int | None = None, gap: float = 0.0
) -> tuple[list[Placed], int, float]:
    """Rzędy jeden za drugim od ``offset``; przed rzędem ``gap_at`` – luka ``gap`` (np. ciężki
    krąg nad osiami, reszta przy ścianie). Zwraca (sztuki, nie zmieszczone sztuki, koniec)."""
    placed, unplaced, x = [], 0, offset
    for index, row in enumerate(rows):
        if index == gap_at:
            x += gap
        if x + row.length > deck_length + 1e-6:
            unplaced += sum(p.pieces for p in row.pieces)
            continue
        placed += [p.model_copy(update={"x_m": round(x, 3)}) for p in row.pieces]
        x += row.length
    return placed, unplaced, x


def _variants(rows: list[_Row]) -> list[list[_Row]]:
    """Kolejność rzędów: jak w planie, w każdym rozładunku cięższe z przodu albo z tyłu."""
    by_stop: dict[int, list[_Row]] = {}
    for row in rows:
        by_stop.setdefault(row.stop, []).append(row)
    stops = list(by_stop)
    heavy_front = [r for s in stops for r in sorted(by_stop[s], key=lambda r: -r.weight)]
    heavy_back = [r for s in stops for r in sorted(by_stop[s], key=lambda r: r.weight)]
    return [rows, heavy_front, heavy_back]


GAP_STEP_M = 0.1
"""Krok luki między rzędami przy szukaniu ułożenia."""
FULL_CHECKS = 40
"""Ile najlepszych (wg nacisków) ułożeń sprawdzić pełną oceną wymagań."""


def _tractor_overload(axles: list[Axle], cargo: CargoInfo | None) -> float:
    """Przekroczenia ciągnika siodłowego [kg]: osie, DMC, za mało na osi napędowej."""
    if not cargo or cargo.kind not in ("semitrailer", "combination") or len(axles) != 2:
        return 0.0
    own = TRACTOR_TARE_KG if cargo.kind == "combination" else TYPICAL_TRACTOR_KG
    tr = tractor(axles[0].load_kg, axles[1].load_kg, own)
    return (
        max(0.0, tr.front_kg - tr.front_limit_kg)
        + max(0.0, tr.drive_kg - tr.drive_limit_kg)
        + max(0.0, DRIVE_MIN_SHARE * tr.gvw_kg - tr.drive_kg)
    )


def problems(out: "PlanOut") -> int:
    """Ile wymagań plan nie spełnia: mieści się (masa, osie, wymiary), mocowanie EN 12195-1,
    VDI 2700, art. 61 (naciski, ciągnik). Kod nadwozia EN 12642 zależy od pojazdu, nie od
    ułożenia."""
    checks = [out.fits, out.forces is None or out.forces.ok, not out.shortages]
    checks += [n.ok for n in out.norms if n.id != "en12642"]
    return sum(1 for ok in checks if not ok)


def layouts(
    rows: list[_Row], deck_length: float, points: list[Support], cargo: CargoInfo | None
) -> list[tuple[tuple, list[Placed], int, float, bool]]:
    """Ułożenia do sprawdzenia: kolejność rzędów × odsunięcie od ściany albo luka przed
    jednym rzędem. Posortowane wg nacisków (osie naczepy i ciągnika), potem bez luk, najbliżej
    ściany czołowej. Zwraca (klucz, sztuki, nie zmieszczone, odstęp od ściany, czy przestawiono)."""
    found = []
    for rank, variant in enumerate(_variants(rows)):
        free = max(0.0, deck_length - _lay(variant, 0.0, deck_length)[2])
        options = [(step * STEP_M, None, 0.0) for step in range(int(free / STEP_M + 1e-9) + 1)]
        options += [
            (0.0, i, step * GAP_STEP_M)
            for i in range(1, len(variant))
            for step in range(1, int(free / GAP_STEP_M + 1e-9) + 1)
        ]
        for offset, gap_at, gap in options:
            placed, unplaced, _ = _lay(variant, offset, deck_length, gap_at, gap)
            axles = axle_loads(placed, points)
            over = _overload(axles) + _tractor_overload(axles, cargo)
            key = (
                unplaced,
                round(over),
                offset > 0,
                gap_at is not None,
                round(offset + gap, 2),
                rank,
            )
            moved = rank > 0 or offset > 0 or gap > 0
            found.append((key, placed, unplaced, round(offset, 2), moved))
    found.sort(key=lambda f: f[0])
    return found


def arrange(
    rows: list[_Row], deck_length: float, points: list[Support]
) -> tuple[list[Placed], int, float, float, bool]:
    """Ułożenie bez przekroczeń nacisków, najbliżej ściany czołowej.

    Zwraca (sztuki, nie zmieszczone, koniec ładunku, odstęp od ściany, czy przestawiono)."""
    placed, unplaced, end = _lay(rows, 0.0, deck_length)
    if not points or _overload(axle_loads(placed, points)) == 0:
        return placed, unplaced, end, 0.0, False
    best = None
    for rank, variant in enumerate(_variants(rows)):
        used = _lay(variant, 0.0, deck_length)[2]
        steps = int(max(0.0, deck_length - used) / STEP_M + 1e-9)
        for step in range(steps + 1):
            offset = step * STEP_M
            laid = _lay(variant, offset, deck_length)
            score = (round(_overload(axle_loads(laid[0], points))), laid[1], offset, rank)
            if best is None or score < best[0]:
                best = (score, laid, offset, rank)
    _, (placed, unplaced, end), offset, rank = best
    return placed, unplaced, end, round(offset, 2), rank > 0 or offset > 0


def evaluate(
    placed: list[Placed], unplaced: int, data: PlanIn, deck_length: float, deck_width: float,
    cargo: CargoInfo | None, offset: float = 0.0, adjusted: bool = False,
    types: Types | None = None,
) -> PlanOut:  # fmt: skip
    """Masa, naciski, pasy i ostrzeżenia dla podanego ułożenia (z planu albo przeciągniętego)."""
    types = types if types is not None else item_types(data)
    payload = cargo.payload_kg if cargo else None
    points = supports(cargo, deck_length)
    front_wall = data.front_wall and offset < STEP_M
    weight = sum(p.weight_kg for p in placed)

    def ctype(p: Placed) -> CargoType | None:
        return types[p.item] if p.item < len(types) else None

    def method(p: Placed) -> Securing:
        c = ctype(p)
        return c.securing if c else "top"

    def mu_of(p: Placed) -> float:
        """Tarcie sztuki o podłogę (EN 12195-1, zał. B); mata antypoślizgowa – co najmniej 0,6."""
        c = ctype(p)
        base = c.mu if c else friction(False)
        return max(base, friction(True)) if data.mats else base

    # Sypkie i płynne trzyma zabudowa – bez pasów i bez bilansu sił.
    held = [p for p in placed if method(p) != "none"]
    mu = min((mu_of(p) for p in held), default=friction(data.mats))
    g = 9.81 / 1000
    rest_forward = sum(max(0.0, 0.8 - mu_of(p)) * p.weight_kg * g for p in held)
    wall = wall_capacity_kN(data.body_code, payload)
    holds = wall_holds(front_wall, data.body_code, wall, rest_forward)
    # Rzędy: sztuki zaczynające się w tym samym miejscu (po przeciągnięciu – każda osobno).
    by_x: dict[float, list[Placed]] = {}
    for p in placed:
        by_x.setdefault(round(p.x_m, 2), []).append(p)
    tensions: dict[float, float] = {}
    for x, ps in by_x.items():
        top = [p for p in ps if method(p) == "top"]
        weight_top = sum(p.weight_kg for p in top)
        mu_top = min((mu_of(p) for p in top), default=1.0)
        tensions[x] = row_tension_daN(weight_top, mu_top, forward=not holds) if top else 0.0
    lcs = [
        direct_lc_daN(p.weight_kg, mu_of(p), forward=not holds)
        for p in held
        if method(p) == "direct"
    ]

    def _has_top(ps: list[Placed]) -> bool:
        return any(method(p) == "top" for p in ps)

    def row_method(ps: list[Placed]) -> str:
        kinds = {method(p) for p in ps}
        return kinds.pop() if len(kinds) == 1 else "mixed"

    rows = [
        Row(
            x_m=x, length_m=max(p.length_m for p in ps), weight_kg=sum(p.weight_kg for p in ps),
            straps=straps_for(tensions[x], data.strap_daN) if _has_top(ps) else 0,
            method=row_method(ps),
            lashings=LASHINGS_PER_PIECE * sum(1 for p in ps if method(p) == "direct"),
        )
        for x, ps in sorted(by_x.items())
    ]  # fmt: skip
    total = sum(i.count * i.weight_kg for i in data.items)  # także sztuki niezmieszczone
    cog = sum((p.x_m + p.length_m / 2) * p.weight_kg for p in placed) / weight if weight else None
    axles = axle_loads(placed, points)
    end = max((p.x_m + p.length_m for p in placed), default=0.0)
    inner = None
    if cargo and cargo.height_m:
        inner = round(cargo.height_m - FLOOR_M.get(cargo.kind, 1.1) - ROOF_M, 2)
    warnings = []
    if unplaced:
        warnings.append(t("load.unplaced", count=unplaced))
    if payload is not None and total > payload:
        warnings.append(t("load.overweight", weight=round(total), payload=round(payload)))
    for axle in axles:
        if axle.over:
            warnings.append(
                t("load.axle_over", axle=t(f"load.axle_{axle.name}"),
                  load=round(axle.load_kg), limit=round(axle.limit_kg or 0))
            )  # fmt: skip
    if not axles and cog is not None:
        # Bez danych o osiach – jak dotąd: tylko środek ciężkości.
        if cog < COG_MIN * deck_length:
            warnings.append(t("load.cog_front", share=round(cog / deck_length * 100)))
        if cog > COG_MAX * deck_length:
            warnings.append(t("load.cog_back", share=round(cog / deck_length * 100)))
    if adjusted and not any(a.over for a in axles):
        warnings.append(t("load.adjusted"))
    # Luki między rzędami (ułożenie nad osiami) – blokada belką.
    ordered = sorted(rows, key=lambda r: r.x_m)
    gaps = [
        (round(b.x_m - (a.x_m + a.length_m), 2), round(b.x_m, 2))
        for a, b in zip(ordered, ordered[1:], strict=False)
        if b.x_m - (a.x_m + a.length_m) >= GAP_STEP_M - 1e-6
    ]
    for gap, x in gaps:
        warnings.append(t("load.gap_inside", gap=gap, x=x))
    if offset >= STEP_M:
        warnings.append(t("load.gap_front", gap=offset))
    if not data.front_wall:
        warnings.append(t("load.no_front_wall"))
    if inner is not None and any(p.height_m > inner + 1e-6 and p.height_known for p in placed):
        warnings.append(t("load.too_high", height=inner))
    if front_wall and not holds:
        warnings.append(t("load.wall_weak", wall=wall or 0, force=round(rest_forward, 1)))
    straps_ok = all(r.straps <= max(1, math.floor(r.length_m * MAX_STRAPS_PER_M)) for r in rows)
    if not straps_ok:
        warnings.append(t("load.too_many_straps"))
    lashing = max(lcs, default=0.0)
    lashing_ok = lashing <= CHAIN_DAN
    if not lashing_ok:
        warnings.append(t("load.lashing_high", force=round(lashing), lc=CHAIN_DAN))
    warnings += _cargo_warnings(placed, data, types, cargo.body if cargo else "")
    tractor_info = None
    if cargo and cargo.kind in ("semitrailer", "combination") and len(axles) == 2:
        own = TRACTOR_TARE_KG if cargo.kind == "combination" else TYPICAL_TRACTOR_KG
        tractor_info = tractor(axles[0].load_kg, axles[1].load_kg, own)
        for problem in tractor_problems(tractor_info):
            warnings.append(
                t(f"load.tractor_{problem}", front=round(tractor_info.front_kg),
                  drive=round(tractor_info.drive_kg), gvw=round(tractor_info.gvw_kg),
                  share=round(tractor_info.drive_share * 100))
            )  # fmt: skip
    outside = [
        p for p in placed
        if p.x_m < -1e-6 or p.y_m < -1e-6 or p.x_m + p.length_m > deck_length + 1e-6
        or p.y_m + p.width_m > deck_width + 1e-6
    ]  # fmt: skip
    if outside:
        warnings.append(t("load.outside", count=len(outside)))
    if _overlaps(placed):
        warnings.append(t("load.overlap"))
    ok_axles = not any(a.over for a in axles)
    straps = sum(r.straps for r in rows)
    airbags = sum(
        1 for ps in by_x.values() if deck_width - sum(p.width_m for p in ps) >= AIRBAG_GAP_M
    )
    gear = equipment(
        straps, len({p.stop for p in placed}) + len(gaps), offset >= STEP_M,
        len([p for p in held if method(p) != "none"]) if data.mats else 0, airbags,
        _extra_gear(placed, types, by_x),
    )  # fmt: skip
    shortages = {}
    if data.available is not None:
        shortages = {
            e.id: e.required - data.available.get(e.id, 0)
            for e in gear
            if e.required > data.available.get(e.id, 0)
        }
    if shortages:
        missing = ", ".join(f"{n} × {t(f'load.gear.{k}')}" for k, n in shortages.items())
        warnings.append(t("load.missing", items=missing))
    fits = not unplaced and (payload is None or total <= payload) and ok_axles and not outside
    secured = straps_ok and lashing_ok and bool(placed)
    tractor_ok = tractor_info is None or not tractor_problems(tractor_info)
    norms = [
        Norm(id="en12642", ok=data.body_code != "unknown" and (holds or not front_wall)),
        Norm(id="en12195", ok=secured),
        Norm(id="vdi2700", ok=secured and not _overlaps(placed) and not outside),
        Norm(id="art61", ok=fits and tractor_ok),
    ]
    places = int(deck_length / EUR[0] + 1e-9) * int(deck_width / EUR[1] + 1e-9)
    used = round(sum(p.length_m * p.width_m for p in placed) / (EUR[0] * EUR[1]))
    return PlanOut(
        deck_length_m=deck_length,
        deck_width_m=deck_width,
        inner_height_m=inner,
        ldm=round(end * deck_width / LDM_WIDTH_M, 2),
        used_length_m=round(end, 2),
        weight_kg=round(total, 1),
        payload_kg=payload,
        fits=fits,
        placed=placed,
        unplaced=unplaced,
        rows=rows,
        straps=straps,
        cog_m=round(cog, 2) if cog is not None else None,
        axles=axles,
        offset_m=offset,
        adjusted=adjusted,
        warnings=warnings,
        body_code=data.body_code,
        reference=data.reference,
        pallet_places=places,
        places_used=min(used, places) if places else used,
        forces=forces(
            weight,
            mu,
            wall,
            front_wall,
            data.body_code,
            sum(tensions.values()),
            straps,
            data.strap_daN,
            secured,
            friction_kN=sum(mu_of(p) * p.weight_kg * g for p in held),
            rest_forward_kN=rest_forward,
            rest_side_kN=sum(max(0.0, 0.5 - mu_of(p)) * p.weight_kg * g for p in held),
            lashings=LASHINGS_PER_PIECE * len(lcs),
            lashing_daN=lashing,
        ),  # fmt: skip
        tractor=tractor_info,
        equipment=gear,
        norms=norms,
        mats=data.mats,
        shortages=shortages,
    )


CONCENTRATED_KG_PER_M = 5_000
"""Ładunek skupiony: ponad tyle kg na metr długości – sprawdzić wykres rozkładu obciążeń."""


def _cargo_warnings(placed: list[Placed], data: PlanIn, types: Types, body: str) -> list[str]:
    """Zabudowa nie do tego towaru, za wysoki stos, ADR, ładunek skupiony."""
    warnings = []
    seen: set[str] = set()
    for index, (item, c) in enumerate(zip(data.items, types, strict=True)):
        if c is None:
            continue
        name = cargo_name(c)
        if not c.allows(body) and c.id not in seen:
            need = sorted({t(f"load.body_group.{BODY_GROUP.get(b, b)}") for b in c.bodies})
            warnings.append(
                t(
                    "load.body_mismatch",
                    cargo=name,
                    body=t(f"load.body.{body}"),
                    need=", ".join(need),
                )
            )
        if item.stack > c.stack:
            warnings.append(t("load.stack_limit", cargo=name, stack=c.stack))
        if c.adr and c.id not in seen:
            warnings.append(t("load.adr", cargo=name))
        heavy = [
            p
            for p in placed
            if p.item == index and p.weight_kg / p.length_m > CONCENTRATED_KG_PER_M
        ]
        if heavy and c.id not in seen:
            per_m = max(p.weight_kg / p.length_m for p in heavy) / 1000
            warnings.append(t("load.concentrated", cargo=name, load=round(per_m, 1)))
        seen.add(c.id)
    return warnings


def _extra_gear(
    placed: list[Placed], types: Types, by_x: dict[float, list[Placed]]
) -> dict[str, int]:
    """Łańcuchy (mocowanie bezpośrednie), kliny, siatki i kłonice wg rodzaju towaru."""

    def gear_of(p: Placed) -> tuple[str, ...]:
        c = types[p.item] if p.item < len(types) else None
        return c.gear if c else ()

    def direct(p: Placed) -> bool:
        c = types[p.item] if p.item < len(types) else None
        return c is not None and c.securing == "direct"

    def rows_length(gear: str) -> float:
        return sum(
            max(p.length_m for p in ps)
            for ps in by_x.values()
            if any(gear in gear_of(p) for p in ps)
        )

    net = rows_length("net")
    stakes = rows_length("stakes")
    return {
        "chains": LASHINGS_PER_PIECE * sum(1 for p in placed if direct(p)),
        "chocks": 2 * sum(1 for p in placed if "chocks" in gear_of(p)),
        "net": math.ceil(net / 4) if net else 0,
        "stakes": 2 * (math.ceil(stakes / 3) + 1) if stakes else 0,
    }


def _overlaps(placed: list[Placed]) -> bool:
    for i, a in enumerate(placed):
        for b in placed[i + 1 :]:
            if (
                a.x_m < b.x_m + b.length_m - 1e-3 and b.x_m < a.x_m + a.length_m - 1e-3
                and a.y_m < b.y_m + b.width_m - 1e-3 and b.y_m < a.y_m + a.width_m - 1e-3
            ):  # fmt: skip
                return True
    return False


def plan(
    data: PlanIn, deck_length: float, deck_width: float, payload: float | None,
    cargo: CargoInfo | None = None, types: Types | None = None,
) -> PlanOut:  # fmt: skip
    if cargo is None:
        cargo = CargoInfo(deck_length_m=deck_length, payload_kg=payload)
    types = types if types is not None else item_types(data)
    # Z wyposażeniem użytkownika: najpierw bez mat, potem z matami (jeśli je ma).
    options = [data]
    if not data.mats and data.available and data.available.get("mats", 0) > 0:
        options.append(data.model_copy(update={"mats": True}))
    best, best_key = None, None
    for index, option in enumerate(options):
        out, key = _search(option, deck_length, deck_width, cargo, types)
        key = (key[0], index, *key[1:])
        if best_key is None or key < best_key:
            best, best_key = out, key
        if key[0] == 0:
            break
    if best.mats and not data.mats:
        need = next((e.required for e in best.equipment if e.id == "mats"), 0)
        best.warnings.insert(0, t("load.proposal_mats", need=need, have=data.available["mats"]))
    if problems(best):
        # Najlepsze możliwe ułożenie – z listą tego, czego nie da się dotrzymać.
        best.warnings = [w for w in best.warnings if w != t("load.adjusted")]
        if best.adjusted:
            best.warnings.insert(0, t("load.adjusted_partly"))
        best.warnings.insert(0, t("load.no_solution"))
    return best


def _search(
    data: PlanIn, deck_length: float, deck_width: float, cargo: CargoInfo, types: Types
) -> tuple[PlanOut, tuple]:
    """Najlepsze ułożenie dla danego mocowania: (plan, klucz – najpierw liczba niespełnionych
    wymagań)."""
    rows = _rows(data, deck_width, types)
    points = supports(cargo, deck_length)
    placed, unplaced, _ = _lay(rows, 0.0, deck_length)
    out = evaluate(placed, unplaced, data, deck_length, deck_width, cargo, 0.0, False, types)
    if problems(out) == 0:
        return out, (0,)  # ułożenie od ściany czołowej spełnia wszystkie wymagania
    # Szukamy ułożenia spełniającego wszystkie wymagania: najpierw najlepsze wg nacisków,
    # dla nich pełna ocena (mocowanie, ściana czołowa, ciągnik, normy).
    # Drugi zestaw rzędów: o sztukę mniej w rzędzie – gdy pasy nie dają rady z pełnymi rzędami.
    best_key = (problems(out), 1 << 30)
    best = out
    for narrow in (False, True):
        row_set = _rows(data, deck_width, types, narrow=True) if narrow else rows
        if narrow and (best_key[0] == 0 or len(row_set) == len(rows)):
            break
        for key, placed, unplaced, offset, moved in layouts(row_set, deck_length, points, cargo)[
            :FULL_CHECKS
        ]:
            candidate = evaluate(
                placed, unplaced, data, deck_length, deck_width, cargo, offset, moved or narrow,
                types,
            )  # fmt: skip
            score = (problems(candidate), key[1], narrow, *key[2:])
            if score < best_key:
                best_key, best = score, candidate
            if score[0] == 0:
                break  # lista jest posortowana – pierwsze ułożenie bez problemów jest najlepsze
    return best, best_key


class CargoTypeOut(BaseModel):
    id: str
    group: str
    name: str
    shape: str
    length_m: float
    width_m: float
    height_m: float
    weight_kg: float
    mu: float
    securing: str
    stack: int
    bodies: list[str]
    gear: list[str]
    kind: str
    adr: bool
    custom: bool


class CargoGroupOut(BaseModel):
    id: str
    name: str


class CargoCatalog(BaseModel):
    groups: list[CargoGroupOut]
    types: list[CargoTypeOut]


class CustomCargoIn(BaseModel):
    """Własny rodzaj towaru: wymiary sztuki, tarcie, mocowanie, piętrowanie."""

    name: str = Field(min_length=1, max_length=60)
    group: str = "other"
    shape: Shape = "box"
    length_m: float = Field(gt=0, le=14)
    width_m: float = Field(gt=0, le=2.6)
    height_m: float = Field(gt=0, le=4)
    weight_kg: float = Field(gt=0, le=40_000)
    mu: float = Field(default=0.3, ge=0.05, le=1.0, description="Tarcie o podłogę bez maty")
    securing: Securing = "top"
    stack: int = Field(default=1, ge=1, le=10)
    bodies: list[str] = Field(default_factory=lambda: list(DECK), max_length=40)
    gear: list[Gear] = Field(default_factory=list, max_length=4)
    adr: bool = False

    @field_validator("group")
    @classmethod
    def _known_group(cls, value: str) -> str:
        if value not in GROUPS:
            raise ValueError("unknown group")
        return value

    @field_validator("bodies")
    @classmethod
    def _known_bodies(cls, value: list[str]) -> list[str]:
        if any(b not in BODY_GROUPS and b not in BODY_GROUP for b in value):
            raise ValueError("unknown body")
        return value or list(DECK)


def custom_type(row: CustomCargo) -> CargoType:
    d = CustomCargoIn.model_validate(row.data)
    return CargoType(
        id=row.id, group=d.group, shape=d.shape, length_m=d.length_m, width_m=d.width_m,
        height_m=d.height_m, weight_kg=d.weight_kg, mu=d.mu, securing=d.securing, stack=d.stack,
        bodies=tuple(d.bodies), gear=tuple(d.gear), adr=d.adr, name=d.name, custom=True,
    )  # fmt: skip


def type_out(c: CargoType) -> CargoTypeOut:
    return CargoTypeOut(
        id=c.id, group=c.group, name=cargo_name(c), shape=c.shape, length_m=c.length_m,
        width_m=c.width_m, height_m=c.height_m, weight_kg=c.weight_kg, mu=c.mu,
        securing=c.securing, stack=c.stack, bodies=list(c.bodies), gear=list(c.gear),
        kind=c.kind, adr=c.adr, custom=c.custom,
    )  # fmt: skip


class LoadModule(Module):
    id = "load"
    name = "Plan załadunku"
    version = "0.2.0"
    requires_core = ">=0.1,<1.0"

    def register(self, ctx: CoreContext) -> None:
        for file in (resources.files("truckmaps_load") / "locales").iterdir():
            if file.name.endswith(".json"):
                i18n.register(file.name.removesuffix(".json"), json.loads(file.read_text("utf-8")))

        router = APIRouter()
        User = Annotated[Principal, Depends(ctx.auth.current_user)]
        Db = Annotated[Session, Depends(ctx.storage.session)]

        def deck(data: PlanIn, user: Principal, db: Session):
            vehicle = ctx.fleet.vehicle(db, user, data.vehicle_id)
            if vehicle is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, t("load.vehicle_not_found"))
            cargo = ctx.fleet.cargo(db, vehicle.id)
            typical = DECKS.get(vehicle.kind)
            length = data.deck_length_m or cargo.deck_length_m or (typical and typical[0])
            width = data.deck_width_m or (typical and typical[1]) or 2.45
            if not length:
                raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, t("load.deck_unknown"))
            return length, width, cargo

        def own_types(db: Session, user: Principal) -> dict[str, CargoType]:
            rows = db.scalars(
                select(CustomCargo)
                .where(CustomCargo.owner == user.subject)
                .order_by(CustomCargo.created_at)
            )
            return {r.id: custom_type(r) for r in rows}

        def types_for(data: PlanIn, user: Principal, db: Session) -> Types:
            custom = (
                own_types(db, user)
                if any(i.cargo and i.cargo not in BUILT_IN for i in data.items)
                else {}
            )
            return item_types(data, custom)

        @router.get("/equipment")
        def get_equipment(user: User, db: Db) -> EquipmentIn:
            """Wyposażenie użytkownika (sprzęt do mocowania, który ma w pojeździe)."""
            row = db.get(OwnEquipment, user.subject)
            return EquipmentIn.model_validate(row.data) if row else EquipmentIn(enabled=False)

        @router.put("/equipment")
        def put_equipment(data: EquipmentIn, user: User, db: Db) -> EquipmentIn:
            row = db.get(OwnEquipment, user.subject)
            if row is None:
                row = OwnEquipment(owner=user.subject, data={}, updated_at=datetime.now(UTC))
                db.add(row)
            row.data = data.model_dump(mode="json")
            row.updated_at = datetime.now(UTC)
            db.commit()
            return data

        @router.get("/cargo-types")
        def cargo_types(user: User, db: Db) -> CargoCatalog:
            """Rodzaje towaru z katalogu i własne rodzaje użytkownika, w grupach."""
            return CargoCatalog(
                groups=[CargoGroupOut(id=g, name=t(f"load.cargo_group.{g}")) for g in GROUPS],
                types=[type_out(c) for c in (*CATALOG, *own_types(db, user).values())],
            )

        @router.post("/cargo-types", status_code=status.HTTP_201_CREATED)
        def add_cargo_type(data: CustomCargoIn, user: User, db: Db) -> CargoTypeOut:
            """Własny rodzaj towaru (widoczny tylko dla autora)."""
            row = CustomCargo(
                id=str(uuid.uuid4()), owner=user.subject, data=data.model_dump(mode="json"),
                created_at=datetime.now(UTC),
            )  # fmt: skip
            db.add(row)
            db.commit()
            return type_out(custom_type(row))

        @router.delete("/cargo-types/{type_id}", status_code=status.HTTP_204_NO_CONTENT)
        def delete_cargo_type(type_id: str, user: User, db: Db) -> None:
            row = db.get(CustomCargo, type_id)
            if row is None or row.owner != user.subject:
                raise HTTPException(status.HTTP_404_NOT_FOUND, t("load.cargo_not_found"))
            db.delete(row)
            db.commit()

        @router.post("/plan")
        def make_plan(data: PlanIn, user: User, db: Db) -> PlanOut:
            """Plan dla pojazdu widocznego dla użytkownika (wymiary, ładowność i osie z profilu)."""
            length, width, cargo = deck(data, user, db)
            return plan(data, length, width, cargo.payload_kg, cargo, types_for(data, user, db))

        def checked(data: PlanIn, placed: list[Placed], length, width, cargo, types) -> PlanOut:
            for p in placed:
                if p.item >= len(data.items):
                    raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, t("load.bad_item"))
            # Ile sztuk z pozycji nie ma na planie (np. przeciągnięte poza – usunięte).
            shown = sum(p.pieces for p in placed)
            unplaced = max(0, sum(i.count for i in data.items) - shown)
            offset = min((p.x_m for p in placed), default=0.0)
            return evaluate(
                placed, unplaced, data, length, width, cargo, round(max(0, offset), 2), types=types
            )

        @router.post("/plan/check")
        def check_plan(data: CheckIn, user: User, db: Db) -> PlanOut:
            """Sprawdzenie ułożenia przeciągniętego przez użytkownika (bez przestawiania)."""
            length, width, cargo = deck(data, user, db)
            return checked(data, data.placed, length, width, cargo, types_for(data, user, db))

        @router.post("/plan/pdf")
        def plan_pdf(data: ExportIn, user: User, db: Db) -> dict:
            """PDF pod krótkim linkiem (15 min): rzut, naciski, siły, lista sprzętu VDI 2700."""
            length, width, cargo = deck(data, user, db)
            types = types_for(data, user, db)
            if data.placed:
                out = checked(data, data.placed, length, width, cargo, types)
            else:
                out = plan(data, length, width, cargo.payload_kg, cargo, types)
            vehicle = ctx.fleet.vehicle(db, user, data.vehicle_id)
            body = report.to_pdf(out, data.items, vehicle, set(data.checked), data.approved)
            name = "-".join(x for x in ("plan", data.reference, vehicle.plate or "") if x)
            name = "".join(c if c.isalnum() or c in "-_" else "_" for c in name)
            return {
                "path": ctx.storage.share(db, body, "application/pdf", f"{name}.pdf"),
                "filename": name,
            }

        ctx.api.include_router(router)
