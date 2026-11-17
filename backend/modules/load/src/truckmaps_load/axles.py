"""Naciski na osie całego pojazdu – metoda momentów (czysta funkcja, bez bazy i HTTP).

Model jak w darmowych planerach nacisków (np. Axle Plan): ładunek dzieli się na sworzeń
i zespół osi naczepy wg odległości od nich, a sworzeń dociska ciągnik – głównie oś
napędową (siodło jest tuż przed nią). Osie naczepy liczone razem, jako jeden zespół.

Współrzędna ``x`` – od ściany czołowej przestrzeni ładunkowej (przed nią: wartość ujemna).

Dopuszczalne naciski (rozporządzenie Ministra Infrastruktury z 31.12.2002 w sprawie
warunków technicznych pojazdów, § 3; dyrektywa 96/53/WE): oś pojedyncza 10 t, oś
napędowa 11,5 t, zespół trzech osi naczepy 24 t (rozstaw 1,3–1,4 m), zespół dwóch osi
18 t (rozstaw 1,3–1,8 m), zespół ciągników siodłowych 40 t, pojazd dwuosiowy 18 t,
trzyosiowy 26 t (oś napędowa z ogumieniem bliźniaczym i zawieszeniem pneumatycznym),
czteroosiowy 32 t. Oś napędowa: co najmniej 25 % masy pojazdu / zespołu.
Oś kierowana: przepisy dopuszczają 10 t, ale producenci ciągników 4×2 podają zwykle
7,1–7,5 t – przyjmujemy 7,5 t (nacisk techniczny), o ile profil nie podaje innego.
Minimalny nacisk osi kierowanej – 20 % masy pojazdu (regulamin EKG ONZ nr 79 /
rozporządzenie (UE) nr 1230/2012 – sterowność); poniżej koła przednie tracą przyczepność.
Wynik jest szacunkiem i nie zastępuje ważenia pojazdu.
"""

from collections.abc import Sequence
from dataclasses import dataclass
from typing import Literal

from pydantic import BaseModel

WARN_RATIO = 0.9
"""Powyżej 90 % limitu – kolor ostrzegawczy (jak w Axle Plan)."""
STEER_MIN_SHARE = 0.2
"""Oś kierowana: co najmniej 20 % masy pojazdu (sterowność)."""
DRIVE_MIN_SHARE = 0.25
"""Oś napędowa: co najmniej 25 % masy zespołu (dyrektywa 96/53/WE)."""
RIGID_GVW_KG = {2: 18_000, 3: 26_000, 4: 32_000}
"""Dopuszczalna masa całkowita samochodu solo wg liczby osi (gdy brak DMC w profilu)."""


@dataclass(frozen=True)
class TractorSetup:
    """Typowy ciągnik siodłowy 4×2 (rozstaw osi 3,8 m) – wymiary d i e jak w Axle Plan;
    można nadpisać. Te same wartości co w ``securing.tractor``."""

    steer_to_kingpin_m: float = 3.2
    """d – oś kierowana → sworzeń (siodło)."""
    kingpin_to_drive_m: float = 0.6
    """e – sworzeń → oś napędowa (siodło przed osią napędową)."""
    tare_kg: float = 7_300
    """Ciągnik z paliwem i kierowcą."""
    front_share: float = 0.7
    """Część masy własnej ciągnika na osi kierowanej."""
    steer_limit_kg: float = 7_500
    drive_limit_kg: float = 11_500
    tractor_limit_kg: float = 18_000
    """Ciągnik dwuosiowy – suma nacisków osi."""
    gross_limit_kg: float = 40_000

    @property
    def wheelbase_m(self) -> float:
        return self.steer_to_kingpin_m + self.kingpin_to_drive_m


TYPICAL_TRACTOR = TractorSetup()


class AxleLoad(BaseModel):
    id: Literal["steer", "drive", "trailer", "front", "rear"]
    x_m: float
    """Położenie osi (środka zespołu) od ściany czołowej."""
    load_kg: float
    limit_kg: float
    ratio: float
    """Wykorzystanie limitu (1,0 = 100 %)."""
    status: Literal["ok", "warn", "over"]
    min_kg: float | None = None
    """Najmniejszy wymagany nacisk (oś kierowana, napędowa) – ``None``: bez minimum."""


class AxleReport(BaseModel):
    kind: Literal["combination", "rigid"]
    axles: list[AxleLoad]
    """Od przodu pojazdu do tyłu."""
    tractor_kg: float | None = None
    """Masa ciągnika (oś kierowana + napędowa); ``None`` – samochód solo."""
    tractor_limit_kg: float | None = None
    gross_kg: float
    gross_limit_kg: float
    drive_share: float
    """Część masy pojazdu / zespołu na osi napędowej."""
    drive_min_share: float = DRIVE_MIN_SHARE
    cog_m: float | None
    """Środek ciężkości ładunku od ściany czołowej."""
    problems: list[str]
    """Klucze: ``over_<oś>``, ``tractor``, ``gross``, ``drive_share``, ``steer_low``,
    ``cargo_back``."""
    estimated: Literal[True] = True


def status(load: float, limit: float) -> Literal["ok", "warn", "over"]:
    if load > limit + 0.5:
        return "over"
    return "warn" if load > WARN_RATIO * limit else "ok"


def _axle(id_: str, x: float, load: float, limit: float, min_kg: float | None = None) -> AxleLoad:
    return AxleLoad(
        id=id_, x_m=round(x, 2), load_kg=round(load), limit_kg=limit,
        ratio=round(load / limit, 3) if limit else 0.0, status=status(load, limit),
        min_kg=round(min_kg) if min_kg is not None else None,
    )  # fmt: skip


def cargo_cog(loads: Sequence[tuple[float, float]]) -> float | None:
    """Środek ciężkości ładunku z par (masa [kg], środek sztuki od ściany czołowej [m])."""
    weight = sum(w for w, _ in loads)
    return sum(w * x for w, x in loads) / weight if weight > 0 else None


def split(
    loads: Sequence[tuple[float, float]], front_x: float, rear_x: float
) -> tuple[float, float]:
    """Rozkład ładunku na dwie podpory (równowaga momentów): (przednia, tylna) [kg]."""
    total = sum(w for w, _ in loads)
    rear = sum(w * (x - front_x) for w, x in loads) / (rear_x - front_x)
    return total - rear, rear


def combination(
    loads: Sequence[tuple[float, float]],
    kingpin_x: float,
    trailer_axles_x: float,
    trailer_tare_kg: float,
    trailer_limit_kg: float,
    tractor: TractorSetup = TYPICAL_TRACTOR,
    kingpin_tare_share: float = 0.35,
) -> AxleReport:
    """Ciągnik 4×2 + naczepa: oś kierowana, napędowa, zespół osi naczepy, masa zespołu."""
    on_kingpin, on_axles = split(loads, kingpin_x, trailer_axles_x)
    on_kingpin += trailer_tare_kg * kingpin_tare_share
    on_axles += trailer_tare_kg * (1 - kingpin_tare_share)
    lead = tractor.kingpin_to_drive_m / tractor.wheelbase_m
    steer = tractor.tare_kg * tractor.front_share + on_kingpin * lead
    drive = tractor.tare_kg * (1 - tractor.front_share) + on_kingpin * (1 - lead)
    tractor_kg = steer + drive
    gross = tractor_kg + on_axles
    axles = [
        _axle("steer", kingpin_x - tractor.steer_to_kingpin_m, steer, tractor.steer_limit_kg,
              STEER_MIN_SHARE * tractor_kg),
        _axle("drive", kingpin_x + tractor.kingpin_to_drive_m, drive, tractor.drive_limit_kg,
              DRIVE_MIN_SHARE * gross),
        _axle("trailer", trailer_axles_x, on_axles, trailer_limit_kg),
    ]  # fmt: skip
    cog = cargo_cog(loads)
    found = [f"over_{a.id}" for a in axles if a.status == "over"]
    if tractor_kg > tractor.tractor_limit_kg + 0.5:
        found.append("tractor")
    if gross > tractor.gross_limit_kg + 0.5:
        found.append("gross")
    share = drive / gross if gross else 0.0
    if share < DRIVE_MIN_SHARE:
        found.append("drive_share")
    if steer < STEER_MIN_SHARE * tractor_kg:
        found.append("steer_low")
    if cog is not None and cog > trailer_axles_x:
        found.append("cargo_back")
    return AxleReport(
        kind="combination", axles=axles, tractor_kg=round(tractor_kg),
        tractor_limit_kg=tractor.tractor_limit_kg, gross_kg=round(gross),
        gross_limit_kg=tractor.gross_limit_kg, drive_share=round(share, 3),
        cog_m=round(cog, 2) if cog is not None else None, problems=found,
    )  # fmt: skip


def rigid(
    loads: Sequence[tuple[float, float]],
    front_x: float,
    rear_x: float,
    tare_kg: float,
    front_limit_kg: float,
    rear_limit_kg: float,
    gross_limit_kg: float,
    front_tare_share: float = 0.6,
) -> AxleReport:
    """Samochód solo: oś przednia (kierowana) i tylna (napędowa, zespół)."""
    front, rear = split(loads, front_x, rear_x)
    front += tare_kg * front_tare_share
    rear += tare_kg * (1 - front_tare_share)
    gross = front + rear
    axles = [
        _axle("front", front_x, front, front_limit_kg, STEER_MIN_SHARE * gross),
        _axle("rear", rear_x, rear, rear_limit_kg, DRIVE_MIN_SHARE * gross),
    ]
    cog = cargo_cog(loads)
    found = [f"over_{a.id}" for a in axles if a.status == "over"]
    if gross > gross_limit_kg + 0.5:
        found.append("gross")
    share = rear / gross if gross else 0.0
    if share < DRIVE_MIN_SHARE:
        found.append("drive_share")
    if front < STEER_MIN_SHARE * gross:
        found.append("steer_low")
    if cog is not None and cog > rear_x:
        found.append("cargo_back")
    return AxleReport(
        kind="rigid", axles=axles, gross_kg=round(gross), gross_limit_kg=gross_limit_kg,
        drive_share=round(share, 3), cog_m=round(cog, 2) if cog is not None else None,
        problems=found,
    )  # fmt: skip
