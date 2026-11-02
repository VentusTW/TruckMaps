"""Ekran zakazów kraju: najbliższe zakazy ruchu ciężarówek na kilka tygodni, zasady i wyjątki.

Te same okna co przy sprawdzaniu trasy (``timebans.windows``), tylko po kolei dzień po dniu.
Święta regionalne (landy w DE) – osobno, z listą regionów, w których obowiązują.
"""

from datetime import date, datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel

from truckmaps.core import timebans
from truckmaps.core.i18n import t
from truckmaps.sdk import Principal

COUNTRIES = ("PL", "DE", "CZ", "SK", "LT")
MAX_DAYS = 60


class BanDay(BaseModel):
    day: date
    starts_at: datetime
    ends_at: datetime
    title: str
    roads: str
    """Których dróg dotyczy (wszystkie, główne, wymienione numery)."""
    verified: bool


class RegionalHoliday(BaseModel):
    day: date
    name: str
    regions: list[str]


class CountryBans(BaseModel):
    country: str
    name: str
    known: bool
    """``False`` – brak kalendarza zakazów dla kraju (nie znaczy, że zakazów nie ma)."""
    vehicles: str
    """Dla jakich pojazdów (np. „DMC powyżej 12 t”)."""
    exceptions: str
    days: list[BanDay]
    regional: list[RegionalHoliday]


def _roads(window: timebans.Window) -> str:
    if window.refs is not None:
        return t("bans.roads_listed", refs=", ".join(sorted(window.refs, key=_ref_order)))
    if window.roads is not None:
        return t("bans.roads_main")
    return t("bans.roads_all")


def _ref_order(ref: str) -> tuple[str, int]:
    digits = "".join(c for c in ref if c.isdigit())
    return ref[0], int(digits or 0)


def country_bans(country: str, start: date, days: int, state: str = "") -> CountryBans:
    known = country in timebans.ZONES and country != "LT"
    found: list[BanDay] = []
    regional: dict[date, RegionalHoliday] = {}
    for offset in range(days):
        day = start + timedelta(days=offset)
        for window in timebans.windows(country, day, state):
            found.append(
                BanDay(
                    day=day,
                    starts_at=window.start,
                    ends_at=window.end,
                    title=t(window.title),
                    roads=_roads(window),
                    verified=window.verified,
                )
            )
        if country == "DE":
            everywhere = timebans.de_holidays(day.year, "")
            for name, states in timebans.DE_REGIONAL.items():
                one = next(iter(states))
                if day not in everywhere and timebans.de_holidays(day.year, one).get(day) == name:
                    regional[day] = RegionalHoliday(day=day, name=name, regions=sorted(states))
    return CountryBans(
        country=country,
        name=t(f"bans.country_{country}"),
        known=known,
        vehicles=t(f"bans.vehicles_{country}"),
        exceptions=t(f"bans.exceptions_{country}"),
        days=found,
        regional=sorted(regional.values(), key=lambda r: r.day),
    )


def build_router(current_user) -> APIRouter:
    router = APIRouter(prefix="/api/timebans", tags=["routes"])

    @router.get("/{country}")
    def bans(
        country: str,
        _user: Annotated[Principal, Depends(current_user)],
        days: Annotated[int, Query(ge=1, le=MAX_DAYS)] = 30,
        state: str = "",
        start: date | None = None,
    ) -> CountryBans:
        """Zakazy ruchu w kraju od dziś (albo ``start``) na ``days`` dni."""
        country = country.upper()
        if country not in COUNTRIES:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("error.country_unknown"))
        today = datetime.now(timebans.ZONES.get(country, timebans.HOME_ZONE)).date()
        return country_bans(country, start or today, days, state.upper())

    return router
