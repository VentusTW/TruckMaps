"""Wyszukiwanie adresów i miejsc (Photon – wyszukiwarka na danych OpenStreetMap)."""

from typing import Annotated, Protocol

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from pydantic import BaseModel

from truckmaps.core.i18n import language, t
from truckmaps.sdk import Principal


class Place(BaseModel):
    label: str
    """Czytelny opis, np. "OSK MIŚ, Chemiczna 5, 33-101 Tarnów"."""
    lat: float
    lon: float
    kind: str = ""
    """Rodzaj obiektu z OSM, np. "house", "street", "city", "amenity:parking"."""


class GeocodingUnavailable(Exception):
    pass


class Geocoder(Protocol):
    def search(
        self, query: str, limit: int = 5, near: tuple[float, float] | None = None
    ) -> list[Place]:
        """Miejsca pasujące do tekstu; ``near`` = (lat, lon) podnosi wyniki z okolicy."""
        ...

    def reverse(self, lat: float, lon: float) -> Place | None: ...


class PhotonGeocoder:
    def __init__(self, url: str, http: httpx.Client | None = None) -> None:
        self._url = url.rstrip("/")
        self._http = http or httpx.Client(timeout=10)

    def search(
        self, query: str, limit: int = 5, near: tuple[float, float] | None = None
    ) -> list[Place]:
        # Ulica w OSM bywa podzielona na wiele odcinków – pobieramy więcej i usuwamy powtórzenia.
        params: dict[str, object] = {"q": query, "limit": limit * 3, "lang": language()}
        if near:
            params["lat"], params["lon"] = near
        unique: dict[str, Place] = {}
        for place in self._places(self._get("/api", params)):
            unique.setdefault(place.label, place)
        return list(unique.values())[:limit]

    def reverse(self, lat: float, lon: float) -> Place | None:
        places = self._places(self._get("/reverse", {"lat": lat, "lon": lon, "lang": language()}))
        return places[0] if places else None

    def _get(self, path: str, params: dict) -> dict:
        try:
            response = self._http.get(f"{self._url}{path}", params=params)
            response.raise_for_status()
            return response.json()
        except (httpx.HTTPError, ValueError) as exc:
            raise GeocodingUnavailable(str(exc)) from exc

    @staticmethod
    def _places(body: dict) -> list[Place]:
        places = []
        for feature in body.get("features", []):
            lon, lat = feature["geometry"]["coordinates"][:2]
            props = feature.get("properties", {})
            places.append(
                Place(
                    label=format_label(props),
                    lat=lat,
                    lon=lon,
                    kind=props.get("type") or props.get("osm_value", ""),
                )
            )
        return places


def format_label(props: dict) -> str:
    """Adres po polsku: nazwa obiektu, ulica z numerem, kod i miejscowość."""
    street = " ".join(filter(None, [props.get("street"), props.get("housenumber")]))
    city = props.get("city") or props.get("town") or props.get("village") or props.get("county")
    locality = " ".join(filter(None, [props.get("postcode"), city]))
    name = props.get("name")
    parts = [name, street or None, locality or None]
    if name and name in (street, city, props.get("street")):
        parts[0] = None  # np. ulica albo miasto jako nazwa – bez powtórzeń
    if not street and parts[0] is None:
        # Sama miejscowość – województwo odróżnia miejscowości o tej samej nazwie.
        parts.append(props.get("state"))
    label = ", ".join(p for p in parts if p)
    return label or props.get("country", "")


def build_router(current_user) -> APIRouter:
    router = APIRouter(prefix="/api/geocode", tags=["geocoding"])
    User = Annotated[Principal, Depends(current_user)]

    @router.get("")
    def search(
        request: Request,
        user: User,
        q: Annotated[str, Query(min_length=2, max_length=200)],
        lat: float | None = None,
        lon: float | None = None,
        limit: Annotated[int, Query(ge=1, le=10)] = 6,
    ) -> list[Place]:
        """Podpowiedzi adresów i miejsc w trakcie pisania."""
        near = (lat, lon) if lat is not None and lon is not None else None
        return _call(lambda: request.app.state.geocoder.search(q, limit, near))

    @router.get("/reverse")
    def reverse(request: Request, user: User, lat: float, lon: float) -> Place | None:
        """Adres najbliższy podanemu punktowi."""
        return _call(lambda: request.app.state.geocoder.reverse(lat, lon))

    return router


def _call(action):
    try:
        return action()
    except GeocodingUnavailable as exc:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE, t("error.geocoding_unavailable")
        ) from exc
