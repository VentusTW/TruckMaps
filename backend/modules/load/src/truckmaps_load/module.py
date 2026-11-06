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
from dataclasses import dataclass
from importlib import resources
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from truckmaps.sdk import CoreContext, Module, Principal, i18n
from truckmaps.sdk.fleet import CargoInfo
from truckmaps.sdk.i18n import t
from truckmaps_load import report
from truckmaps_load.securing import (
    AIRBAG_GAP_M,
    MAX_STRAPS_PER_M,
    STEER_AXLE_KG,
    TRACTOR_TARE_KG,
    TYPICAL_TRACTOR_KG,
    BodyCode,
    Equipment,
    Forces,
    Norm,
    Tractor,
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


class Item(BaseModel):
    kind: Literal["euro", "industrial", "half", "custom"] = "euro"
    length_m: float | None = Field(default=None, gt=0, le=14, description="Tylko „custom”")
    width_m: float | None = Field(default=None, gt=0, le=2.6, description="Tylko „custom”")
    height_m: float | None = Field(default=None, gt=0, le=3.5, description="Wysokość sztuki")
    count: int = Field(ge=1, le=100)
    weight_kg: float = Field(gt=0, le=30_000, description="Masa jednej sztuki")
    stack: int = Field(default=1, ge=1, le=3, description="Ile sztuk w stosie")
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


def _footprint(item: Item) -> tuple[float, float]:
    if item.kind == "custom":
        if item.length_m is None or item.width_m is None:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, t("load.custom_size"))
        return item.length_m, item.width_m
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


@dataclass
class _Row:
    stop: int
    length: float
    pieces: list[Placed]
    """Sztuki rzędu z ``x_m`` = 0."""

    @property
    def weight(self) -> float:
        return sum(p.weight_kg for p in self.pieces)


def _rows(data: PlanIn, deck_width: float) -> list[_Row]:
    """Rzędy po kolei od przodu: ostatni rozładunek pierwszy."""
    order = sorted(range(len(data.items)), key=lambda i: -data.items[i].stop)
    rows: list[_Row] = []
    for index in order:
        item = data.items[index]
        length, width = _footprint(item)
        along, across, per_row = _row_layout(length, width, deck_width)
        stacks = math.ceil(item.count / item.stack)
        piece_m = item.height_m or DEFAULT_HEIGHT_M
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


def _lay(rows: list[_Row], offset: float, deck_length: float) -> tuple[list[Placed], int, float]:
    """Rzędy jeden za drugim od ``offset``: (sztuki, nie zmieszczone sztuki, koniec ładunku)."""
    placed, unplaced, x = [], 0, offset
    for row in rows:
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
) -> PlanOut:  # fmt: skip
    """Masa, naciski, pasy i ostrzeżenia dla podanego ułożenia (z planu albo przeciągniętego)."""
    payload = cargo.payload_kg if cargo else None
    points = supports(cargo, deck_length)
    front_wall = data.front_wall and offset < STEP_M
    weight = sum(p.weight_kg for p in placed)
    mu = friction(data.mats)
    wall = wall_capacity_kN(data.body_code, payload)
    rest_forward = max(0.0, (0.8 - mu) * weight * 9.81 / 1000)
    holds = wall_holds(front_wall, data.body_code, wall, rest_forward)
    # Rzędy: sztuki zaczynające się w tym samym miejscu (po przeciągnięciu – każda osobno).
    by_x: dict[float, list[Placed]] = {}
    for p in placed:
        by_x.setdefault(round(p.x_m, 2), []).append(p)
    tensions = {
        x: row_tension_daN(sum(p.weight_kg for p in ps), mu, forward=not holds)
        for x, ps in by_x.items()
    }
    rows = [
        Row(
            x_m=x, length_m=max(p.length_m for p in ps), weight_kg=sum(p.weight_kg for p in ps),
            straps=straps_for(tensions[x], data.strap_daN),
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
        straps, len({p.stop for p in placed}), offset >= STEP_M,
        len(placed) if data.mats else 0, airbags,
    )  # fmt: skip
    fits = not unplaced and (payload is None or total <= payload) and ok_axles and not outside
    secured = straps_ok and bool(placed)
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
        ),
        tractor=tractor_info,
        equipment=gear,
        norms=norms,
    )


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
    cargo: CargoInfo | None = None,
) -> PlanOut:  # fmt: skip
    if cargo is None:
        cargo = CargoInfo(deck_length_m=deck_length, payload_kg=payload)
    rows = _rows(data, deck_width)
    placed, unplaced, _, offset, adjusted = arrange(rows, deck_length, supports(cargo, deck_length))
    return evaluate(placed, unplaced, data, deck_length, deck_width, cargo, offset, adjusted)


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

        @router.post("/plan")
        def make_plan(data: PlanIn, user: User, db: Db) -> PlanOut:
            """Plan dla pojazdu widocznego dla użytkownika (wymiary, ładowność i osie z profilu)."""
            length, width, cargo = deck(data, user, db)
            return plan(data, length, width, cargo.payload_kg, cargo)

        def checked(data: PlanIn, placed: list[Placed], length, width, cargo) -> PlanOut:
            for p in placed:
                if p.item >= len(data.items):
                    raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, t("load.bad_item"))
            # Ile sztuk z pozycji nie ma na planie (np. przeciągnięte poza – usunięte).
            shown = sum(p.pieces for p in placed)
            unplaced = max(0, sum(i.count for i in data.items) - shown)
            offset = min((p.x_m for p in placed), default=0.0)
            return evaluate(placed, unplaced, data, length, width, cargo, round(max(0, offset), 2))

        @router.post("/plan/check")
        def check_plan(data: CheckIn, user: User, db: Db) -> PlanOut:
            """Sprawdzenie ułożenia przeciągniętego przez użytkownika (bez przestawiania)."""
            length, width, cargo = deck(data, user, db)
            return checked(data, data.placed, length, width, cargo)

        @router.post("/plan/pdf")
        def plan_pdf(data: ExportIn, user: User, db: Db) -> dict:
            """PDF pod krótkim linkiem (15 min): rzut, naciski, siły, lista sprzętu VDI 2700."""
            length, width, cargo = deck(data, user, db)
            if data.placed:
                out = checked(data, data.placed, length, width, cargo)
            else:
                out = plan(data, length, width, cargo.payload_kg, cargo)
            vehicle = ctx.fleet.vehicle(db, user, data.vehicle_id)
            body = report.to_pdf(out, data.items, vehicle, set(data.checked), data.approved)
            name = "-".join(x for x in ("plan", data.reference, vehicle.plate or "") if x)
            name = "".join(c if c.isalnum() or c in "-_" else "_" for c in name)
            return {
                "path": ctx.storage.share(db, body, "application/pdf", f"{name}.pdf"),
                "filename": name,
            }

        ctx.api.include_router(router)
