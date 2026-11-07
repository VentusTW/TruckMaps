"""Zabezpieczenie ładunku: bilans sił EN 12195-1, ściana czołowa EN 12642, ciągnik, sprzęt VDI 2700.

Wszystko poglądowo – uproszczone wzory dla mocowania przez docisk (pas pionowo, sin α = 1)
i typowa geometria ciągnika siodłowego. Za mocowanie odpowiadają ładujący i kierowca.
"""

import math
from typing import Literal

from pydantic import BaseModel

G = 9.81
SAFETY = 1.1
"""Współczynnik bezpieczeństwa ``f_s`` dla mocowania przez docisk (EN 12195-1)."""
# Przyspieszenia w transporcie drogowym (EN 12195-1): do przodu 0,8 g, na boki i do tyłu 0,5 g.
C_FORWARD, C_SIDE, C_BACK = 0.8, 0.5, 0.5
FRICTION = {"none": 0.3, "mat": 0.6}
"""Tarcie palety o podłogę: bez maty (drewno – sklejka) i z matą antypoślizgową."""

BodyCode = Literal["unknown", "L", "XL"]
# Ściana czołowa wg EN 12642: część ładowności P, którą przenosi (kod L – najwyżej 5000 daN).
WALL_SHARE = {"L": 0.4, "XL": 0.5}
WALL_MAX_DAN = {"L": 5000.0}

MAX_STRAPS_PER_M = 3.4
"""Ile pasów da się rozsądnie założyć na metr długości rzędu (co ok. 30 cm)."""
AIRBAG_GAP_M = 0.15
"""Luka w poprzek rzędu, od której wypełniamy ją poduszką sztauerską."""

# Ciągnik siodłowy (typowy 4×2), gdy nie znamy jego profilu.
TRACTOR_TARE_KG = 8_000
"""Masa ciągnika w masie własnej zestawu (rodzaj „combination”) – reszta to naczepa."""
TYPICAL_TRACTOR_KG = 7_300
"""Ciągnik do naczepy, gdy nie znamy jego profilu (4×2 z paliwem)."""
TRACTOR_FRONT_SHARE = 0.7
"""Część masy własnej ciągnika na osi przedniej."""
TRACTOR_WHEELBASE_M = 3.8
FIFTH_WHEEL_LEAD_M = 0.6
"""Siodło przed osią napędową."""
STEER_AXLE_KG = 7_500
DRIVE_AXLE_KG = 11_500
"""Oś napędowa (dyrektywa 96/53/WE)."""
GVW_LIMIT_KG = 40_000
DRIVE_MIN_SHARE = 0.25
"""Oś napędowa: co najmniej 25 % masy zespołu (dyrektywa 96/53/WE)."""


def friction(mats: bool) -> float:
    return FRICTION["mat" if mats else "none"]


def row_tension_daN(weight_kg: float, mu: float, forward: bool) -> float:
    """Suma napięć wstępnych pasów (STF) potrzebna dla rzędu [daN], wg EN 12195-1.

    ``F_T ≥ f_s · m · g · (c − μ) / (2 · μ)`` dla każdego kierunku, w którym tarcie nie wystarcza;
    do przodu tylko wtedy, gdy ładunku nie trzyma ściana czołowa (``forward``)."""
    needed = 0.0
    for c in [C_SIDE, C_BACK] + ([C_FORWARD] if forward else []):
        if c > mu:
            needed = max(needed, SAFETY * weight_kg * G * (c - mu) / (2 * mu))
    return needed / 10  # N → daN


# Mocowanie bezpośrednie (łańcuchy / pasy przy ładunku), uproszczone wg EN 12195-1:
# 4 odciągi pod kątem α = 45° do podłogi i β = 30° do osi pojazdu, na kierunek pracują 2.
DIRECT_SAFETY = 1.25
LASHINGS_PER_PIECE = 4
CHAIN_DAN = 5_000
"""Dopuszczalna siła mocowania (LC) łańcucha 8 mm klasy 8."""
_SIN_A = math.sin(math.radians(45))
_K_LONG = math.cos(math.radians(45)) * math.cos(math.radians(30))
_K_SIDE = math.cos(math.radians(45)) * math.sin(math.radians(30))


def direct_lc_daN(weight_kg: float, mu: float, forward: bool) -> float:
    """Wymagana siła LC jednego odciągu przy mocowaniu bezpośrednim [daN]."""
    needed = 0.0
    for c, k in [(C_SIDE, _K_SIDE), (C_BACK, _K_LONG)] + (
        [(C_FORWARD, _K_LONG)] if forward else []
    ):
        if c > mu:
            needed = max(needed, DIRECT_SAFETY * weight_kg * G * (c - mu) / (2 * (mu * _SIN_A + k)))
    return needed / 10


def straps_for(tension_daN: float, strap_daN: int) -> int:
    return max(1, math.ceil(tension_daN / strap_daN - 1e-9))


def wall_capacity_kN(code: BodyCode, payload_kg: float | None) -> float | None:
    """Siła, którą przenosi ściana czołowa z certyfikatem EN 12642 [kN]; ``None`` – nie wiadomo."""
    if code not in WALL_SHARE or not payload_kg:
        return None
    dan = WALL_SHARE[code] * payload_kg * G / 10
    return round(min(dan, WALL_MAX_DAN.get(code, dan)) / 100, 1)


class Forces(BaseModel):
    """Bilans sił EN 12195-1:2010 dla całego ładunku."""

    mass_kg: float
    mu: float
    forward_kN: float
    """Siła bezwładności przy hamowaniu (0,8 g)."""
    side_kN: float
    """Siła bezwładności na łuku (0,5 g)."""
    friction_kN: float
    rest_forward_kN: float
    """Do przodu: do przejęcia przez ścianę czołową albo mocowanie."""
    rest_side_kN: float
    wall_kN: float | None
    """Ściana czołowa wg kodu nadwozia; ``None`` – kod nieznany albo brak ładowności."""
    wall_holds: bool
    """Ściana czołowa przejmuje siłę do przodu (ładunek oparty i ściana wystarcza)."""
    tension_daN: float
    """Wymagana suma napięć wstępnych pasów."""
    straps: int
    strap_daN: int
    ok: bool
    """Liczba pasów da się założyć na długości rzędów, odciągi mają wystarczające LC."""
    lashings: int = 0
    """Odciągi mocowania bezpośredniego (łańcuchy / pasy przy ładunku)."""
    lashing_daN: float = 0
    """Największa wymagana siła LC jednego odciągu."""
    chain_daN: int = CHAIN_DAN


def forces(
    mass_kg: float, mu: float, wall_kN: float | None, against_wall: bool, code: BodyCode,
    tension_daN: float, straps: int, strap_daN: int, ok: bool, *,
    friction_kN: float | None = None, rest_forward_kN: float | None = None,
    rest_side_kN: float | None = None, lashings: int = 0, lashing_daN: float = 0,
) -> Forces:  # fmt: skip
    """Bilans; przy różnych towarach tarcie i reszty sił liczone sztuka po sztuce (podane)."""
    kn = mass_kg * G / 1000
    rest_forward = max(0.0, (C_FORWARD - mu) * kn) if rest_forward_kN is None else rest_forward_kN
    rest_side = max(0.0, (C_SIDE - mu) * kn) if rest_side_kN is None else rest_side_kN
    return Forces(
        mass_kg=round(mass_kg, 1),
        mu=mu,
        forward_kN=round(C_FORWARD * kn, 1),
        side_kN=round(C_SIDE * kn, 1),
        friction_kN=round(mu * kn if friction_kN is None else friction_kN, 1),
        rest_forward_kN=round(rest_forward, 1),
        rest_side_kN=round(rest_side, 1),
        wall_kN=wall_kN,
        wall_holds=wall_holds(against_wall, code, wall_kN, rest_forward),
        tension_daN=round(tension_daN),
        straps=straps,
        strap_daN=strap_daN,
        ok=ok,
        lashings=lashings,
        lashing_daN=round(lashing_daN),
    )


def wall_holds(against_wall: bool, code: BodyCode, wall_kN: float | None, rest_kN: float) -> bool:
    """Ładunek oparty o ścianę czołową; przy znanym kodzie nadwozia – ściana musi wystarczyć."""
    if not against_wall:
        return False
    if code == "unknown":
        return True  # jak dotąd: zakładamy ścianę zdolną przejąć ładunek
    return wall_kN is not None and wall_kN + 1e-6 >= rest_kN


class Tractor(BaseModel):
    """Naciski ciągnika siodłowego (typowa geometria 4×2) i masa całkowita zespołu."""

    front_kg: float
    front_limit_kg: float
    drive_kg: float
    drive_limit_kg: float
    gvw_kg: float
    gvw_limit_kg: float
    drive_share: float
    """Część masy zespołu na osi napędowej (wymagane co najmniej 25 %)."""
    estimated: Literal[True] = True


def tractor(
    kingpin_kg: float, trailer_axles_kg: float, tare_kg: float = TYPICAL_TRACTOR_KG
) -> Tractor:
    lead = FIFTH_WHEEL_LEAD_M / TRACTOR_WHEELBASE_M
    front = tare_kg * TRACTOR_FRONT_SHARE + kingpin_kg * lead
    drive = tare_kg * (1 - TRACTOR_FRONT_SHARE) + kingpin_kg * (1 - lead)
    gvw = front + drive + trailer_axles_kg
    return Tractor(
        front_kg=round(front),
        front_limit_kg=STEER_AXLE_KG,
        drive_kg=round(drive),
        drive_limit_kg=DRIVE_AXLE_KG,
        gvw_kg=round(gvw),
        gvw_limit_kg=GVW_LIMIT_KG,
        drive_share=round(drive / gvw, 3) if gvw else 0.0,
    )


def tractor_problems(t: Tractor) -> list[str]:
    """Klucze ostrzeżeń: ``front``, ``drive``, ``gvw``, ``drive_share``."""
    found = []
    if t.front_kg > t.front_limit_kg + 0.5:
        found.append("front")
    if t.drive_kg > t.drive_limit_kg + 0.5:
        found.append("drive")
    if t.gvw_kg > t.gvw_limit_kg + 0.5:
        found.append("gvw")
    if t.drive_share < DRIVE_MIN_SHARE:
        found.append("drive_share")
    return found


class Equipment(BaseModel):
    """Pozycja listy sprzętu (VDI 2700): ile sztuk potrzeba."""

    id: Literal["straps", "edges", "beams", "mats", "airbags", "chains", "chocks", "net", "stakes"]
    required: int


def equipment(
    straps: int, stops: int, front_gap: bool, mats: int, airbags: int,
    extra: dict[str, int] | None = None,
) -> list[Equipment]:  # fmt: skip
    """Lista sprzętu; ``extra`` – łańcuchy, kliny, siatki, kłonice (gdy potrzebne)."""
    more = [Equipment(id=k, required=v) for k, v in (extra or {}).items() if v > 0]
    return more + [
        Equipment(id="straps", required=straps),
        Equipment(id="edges", required=straps * 2),  # dwa narożniki na pas (obie krawędzie)
        # Belka za każdym rozładunkiem poza ostatnim i przy luce przy ścianie czołowej.
        Equipment(id="beams", required=max(0, stops - 1) + (1 if front_gap else 0)),
        Equipment(id="mats", required=mats),
        Equipment(id="airbags", required=airbags),
    ]


class Norm(BaseModel):
    id: Literal["en12642", "en12195", "vdi2700", "art61"]
    ok: bool
