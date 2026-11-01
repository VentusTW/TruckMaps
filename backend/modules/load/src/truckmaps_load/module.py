"""Plan załadunku (M12): LDM, masa, czy się mieści, rozmieszczenie palet i mocowanie.

Palety układamy rzędami od ściany czołowej; ładunek ostatniego rozładunku idzie na przód,
pierwszego – przy drzwiach. W rzędzie wybieramy ułożenie, które zajmuje najmniej długości
(np. palety EUR 3 wzdłuż w rzędzie 1,2 m – 33 na 13,6 m; przemysłowe 2 w poprzek w rzędzie
1,0 m – 26). Mocowanie: liczba pasów przy mocowaniu przez docisk (top-over) wg uproszczonego
wzoru EN 12195-1. To pomoc, nie certyfikat – za zabezpieczenie ładunku odpowiadają
ładujący i kierowca.
"""

import json
import math
from importlib import resources
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from truckmaps.sdk import CoreContext, Module, Principal, i18n
from truckmaps.sdk.i18n import t

LDM_WIDTH_M = 2.4
"""Metr ładowny: 1 m długości przestrzeni o szerokości 2,4 m."""
G = 9.81
SAFETY = 1.1
"""Współczynnik bezpieczeństwa ``f_s`` dla mocowania przez docisk (EN 12195-1)."""
# Przyspieszenia w transporcie drogowym (EN 12195-1): do przodu 0,8 g, na boki i do tyłu 0,5 g.
C_FORWARD, C_SIDE, C_BACK = 0.8, 0.5, 0.5
FRICTION = {"none": 0.3, "mat": 0.6}
"""Tarcie palety o podłogę: bez maty (drewno – sklejka) i z matą antypoślizgową."""
# Rozsądny środek ciężkości ładunku (część długości od ściany czołowej): z przodu przeciąża
# siodło / przednią oś, z tyłu odciąża oś kierowaną ciągnika.
COG_MIN, COG_MAX = 0.35, 0.6

PALLETS = {"euro": (1.2, 0.8), "industrial": (1.2, 1.0), "half": (0.8, 0.6)}
# Typowa przestrzeń ładunkowa, gdy pojazd nie ma jej w profilu: (długość, szerokość) [m].
DECKS = {"semitrailer": (13.6, 2.48), "combination": (13.6, 2.48)}


class Item(BaseModel):
    kind: Literal["euro", "industrial", "half", "custom"] = "euro"
    length_m: float | None = Field(default=None, gt=0, le=14, description="Tylko „custom”")
    width_m: float | None = Field(default=None, gt=0, le=2.6, description="Tylko „custom”")
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


class Row(BaseModel):
    x_m: float
    length_m: float
    weight_kg: float
    straps: int


class PlanOut(BaseModel):
    deck_length_m: float
    deck_width_m: float
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
    warnings: list[str]
    estimated: Literal[True] = True


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


def _straps(weight_kg: float, data: PlanIn) -> int:
    """Pasy na rząd przy mocowaniu przez docisk (pionowo, sin α = 1), wg EN 12195-1."""
    mu = FRICTION["mat" if data.mats else "none"]
    force = data.strap_daN * 10  # daN → N
    needed = 0.0
    for c in [C_SIDE, C_BACK] + ([] if data.front_wall else [C_FORWARD]):
        if c > mu:
            needed = max(needed, SAFETY * weight_kg * G * (c - mu) / (2 * mu * force))
    return max(1, math.ceil(needed - 1e-9))


def plan(data: PlanIn, deck_length: float, deck_width: float, payload: float | None) -> PlanOut:
    # Ostatni rozładunek z przodu: najpierw najwyższe numery rozładunku.
    order = sorted(range(len(data.items)), key=lambda i: -data.items[i].stop)
    placed: list[Placed] = []
    rows: list[Row] = []
    x = 0.0
    unplaced = 0
    for index in order:
        item = data.items[index]
        length, width = _footprint(item)
        along, across, per_row = _row_layout(length, width, deck_width)
        stacks = math.ceil(item.count / item.stack)
        left = item.count
        for start in range(0, stacks, per_row):
            in_row = min(per_row, stacks - start)
            if x + along > deck_length + 1e-6:
                unplaced += left
                break
            row_weight = 0.0
            for k in range(in_row):
                pieces = min(item.stack, left)
                left -= pieces
                weight = pieces * item.weight_kg
                row_weight += weight
                placed.append(
                    Placed(
                        item=index, x_m=round(x, 3), y_m=round(k * across, 3),
                        length_m=along, width_m=across, weight_kg=weight, stop=item.stop,
                    )
                )  # fmt: skip
            rows.append(Row(x_m=round(x, 3), length_m=along, weight_kg=row_weight, straps=0))
            x += along
    rows = [r.model_copy(update={"straps": _straps(r.weight_kg, data)}) for r in rows]
    weight = sum(p.weight_kg for p in placed)
    total = sum(i.count * i.weight_kg for i in data.items)
    cog = sum((p.x_m + p.length_m / 2) * p.weight_kg for p in placed) / weight if weight else None
    warnings = []
    if unplaced:
        warnings.append(t("load.unplaced", count=unplaced))
    if payload is not None and total > payload:
        warnings.append(t("load.overweight", weight=round(total), payload=round(payload)))
    if cog is not None and cog < COG_MIN * deck_length:
        warnings.append(t("load.cog_front", share=round(cog / deck_length * 100)))
    if cog is not None and cog > COG_MAX * deck_length:
        warnings.append(t("load.cog_back", share=round(cog / deck_length * 100)))
    if not data.front_wall:
        warnings.append(t("load.no_front_wall"))
    return PlanOut(
        deck_length_m=deck_length,
        deck_width_m=deck_width,
        ldm=round(x * deck_width / LDM_WIDTH_M, 2),
        used_length_m=round(x, 2),
        weight_kg=round(total, 1),
        payload_kg=payload,
        fits=not unplaced and (payload is None or total <= payload),
        placed=placed,
        unplaced=unplaced,
        rows=rows,
        straps=sum(r.straps for r in rows),
        cog_m=round(cog, 2) if cog is not None else None,
        warnings=warnings,
    )


class LoadModule(Module):
    id = "load"
    name = "Plan załadunku"
    version = "0.1.0"
    requires_core = ">=0.1,<1.0"

    def register(self, ctx: CoreContext) -> None:
        for file in (resources.files("truckmaps_load") / "locales").iterdir():
            if file.name.endswith(".json"):
                i18n.register(file.name.removesuffix(".json"), json.loads(file.read_text("utf-8")))

        router = APIRouter()
        User = Annotated[Principal, Depends(ctx.auth.current_user)]
        Db = Annotated[Session, Depends(ctx.storage.session)]

        @router.post("/plan")
        def make_plan(data: PlanIn, user: User, db: Db) -> PlanOut:
            """Plan dla pojazdu widocznego dla użytkownika (wymiary i ładowność z profilu)."""
            vehicle = ctx.fleet.vehicle(db, user, data.vehicle_id)
            if vehicle is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, t("load.vehicle_not_found"))
            cargo = ctx.fleet.cargo(db, vehicle.id)
            deck = DECKS.get(vehicle.kind)
            length = data.deck_length_m or cargo.deck_length_m or (deck and deck[0])
            width = data.deck_width_m or (deck and deck[1]) or 2.45
            if not length:
                raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, t("load.deck_unknown"))
            return plan(data, length, width, cargo.payload_kg)

        ctx.api.include_router(router)
