"""Znaki ograniczeń na mapie (np. „12 t”, „3,5 m”) z bazy ograniczeń – także poza trasą.

Aplikacja pyta o widoczny fragment mapy przy większym przybliżeniu; szeroki obszar (cały kraj)
zwraca pustą listę, żeby mapa nie zasypała się znakami i baza nie liczyła milionów wierszy.
"""

from typing import Annotated

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.orm import Session

from truckmaps.core.db import get_session
from truckmaps.core.restrictions import Kind, Restriction
from truckmaps.core.route_analysis import PLAUSIBLE
from truckmaps.sdk import Principal

SIGN_KINDS = (Kind.WEIGHT, Kind.WEIGHT_RATING, Kind.AXLE_LOAD, Kind.HEIGHT, Kind.WIDTH)
MAX_SPAN_DEG = 1.0
"""Większy obszar (mniejsze przybliżenie) – bez znaków."""
MAX_SIGNS = 400


class Sign(BaseModel):
    kind: str
    value: float
    lat: float
    lon: float


def signs_in(
    db: Session, min_lat: float, min_lon: float, max_lat: float, max_lon: float
) -> list[Sign]:
    if max_lat - min_lat > MAX_SPAN_DEG or max_lon - min_lon > MAX_SPAN_DEG:
        return []
    query = (
        select(Restriction)
        .where(
            Restriction.kind.in_([k.value for k in SIGN_KINDS]),
            Restriction.value.is_not(None),
            # Indeks (min_lat, min_lon): obiekty zaczynające się w obszarze (z małym zapasem).
            Restriction.min_lat.between(min_lat - 0.01, max_lat),
            Restriction.min_lon.between(min_lon - 0.01, max_lon),
        )
        .limit(MAX_SIGNS * 3)
    )
    seen: set[tuple] = set()
    out: list[Sign] = []
    for r in db.scalars(query):
        low, high = PLAUSIBLE.get(Kind(r.kind), (0, 1000))
        if not low <= r.value <= high:
            continue
        lat = r.lat if r.lat is not None else ((r.min_lat or 0) + (r.max_lat or r.min_lat or 0)) / 2
        lon = r.lon if r.lon is not None else ((r.min_lon or 0) + (r.max_lon or r.min_lon or 0)) / 2
        if not (min_lat <= lat <= max_lat and min_lon <= lon <= max_lon):
            continue
        key = (r.kind, r.value, round(lat, 3), round(lon, 3))
        if key in seen:
            continue
        seen.add(key)
        out.append(Sign(kind=r.kind, value=r.value, lat=lat, lon=lon))
        if len(out) >= MAX_SIGNS:
            break
    return out


def build_router(current_user) -> APIRouter:
    router = APIRouter(tags=["map"])

    @router.get("/api/map/signs")
    def map_signs(
        user: Annotated[Principal, Depends(current_user)],
        db: Annotated[Session, Depends(get_session)],
        min_lat: Annotated[float, Query(ge=-90, le=90)],
        min_lon: Annotated[float, Query(ge=-180, le=180)],
        max_lat: Annotated[float, Query(ge=-90, le=90)],
        max_lon: Annotated[float, Query(ge=-180, le=180)],
    ) -> list[Sign]:
        return signs_in(db, min_lat, min_lon, max_lat, max_lon)

    return router
