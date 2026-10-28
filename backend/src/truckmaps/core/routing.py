"""Wyznaczanie trasy dla ciężarówki (Valhalla, koszt ``truck``)."""

from typing import Annotated, Protocol

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from truckmaps.core.db import get_session
from truckmaps.core.vehicles import VehicleIn, VehicleOut, load_owned
from truckmaps.sdk import Principal

# Kod Valhalli: "No path could be found for input".
VALHALLA_NO_ROUTE = 442


class Point(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)


class RouteRequest(BaseModel):
    origin: Point
    destination: Point
    vehicle_id: str


class Route(BaseModel):
    distance_km: float
    duration_min: float
    geometry: list[tuple[float, float]] = Field(description="Punkty trasy jako [lon, lat]")


class RouteResponse(Route):
    vehicle: VehicleOut


class NoRouteFound(Exception):
    pass


class RoutingUnavailable(Exception):
    pass


class Router(Protocol):
    def route(self, origin: Point, destination: Point, vehicle: VehicleIn) -> Route: ...


class ValhallaRouter:
    def __init__(self, url: str, http: httpx.Client | None = None) -> None:
        self._url = url.rstrip("/")
        self._http = http or httpx.Client(timeout=60)

    def route(self, origin: Point, destination: Point, vehicle: VehicleIn) -> Route:
        request = {
            "locations": [
                {"lat": origin.lat, "lon": origin.lon},
                {"lat": destination.lat, "lon": destination.lon},
            ],
            "costing": "truck",
            "costing_options": {"truck": truck_options(vehicle)},
            "units": "kilometers",
            "directions_type": "none",
        }
        try:
            response = self._http.post(f"{self._url}/route", json=request)
        except httpx.HTTPError as exc:
            raise RoutingUnavailable(str(exc)) from exc
        body = response.json() if response.content else {}
        if response.status_code == 400 and body.get("error_code") == VALHALLA_NO_ROUTE:
            raise NoRouteFound(body.get("error", ""))
        if response.is_error:
            raise RoutingUnavailable(f"Valhalla {response.status_code}: {body.get('error')}")

        trip = body["trip"]
        geometry = [point for leg in trip["legs"] for point in decode_polyline6(leg["shape"])]
        return Route(
            distance_km=round(trip["summary"]["length"], 1),
            duration_min=round(trip["summary"]["time"] / 60, 1),
            geometry=geometry,
        )


def truck_options(vehicle: VehicleIn) -> dict:
    """Parametry pojazdu w jednostkach Valhalli: metry i tony metryczne."""
    return {
        "height": vehicle.height_m,
        "width": vehicle.width_m,
        "length": vehicle.length_m,
        "weight": vehicle.weight_t,
        "axle_load": vehicle.axle_load_t,
        "axle_count": vehicle.axle_count,
        "hazmat": vehicle.hazmat,
    }


def decode_polyline6(encoded: str) -> list[tuple[float, float]]:
    """Dekoduje polilinię Valhalli (precyzja 1e-6) do listy [lon, lat]."""
    points, index, lat, lon = [], 0, 0, 0
    while index < len(encoded):
        deltas = []
        for _ in range(2):
            shift = result = 0
            while True:
                byte = ord(encoded[index]) - 63
                index += 1
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20:
                    break
            deltas.append(~(result >> 1) if result & 1 else result >> 1)
        lat += deltas[0]
        lon += deltas[1]
        points.append((lon / 1e6, lat / 1e6))
    return points


def build_router(current_user) -> APIRouter:
    router = APIRouter(prefix="/api/routes", tags=["routes"])

    @router.post("")
    def calculate_route(
        data: RouteRequest,
        request: Request,
        user: Annotated[Principal, Depends(current_user)],
        db: Annotated[Session, Depends(get_session)],
    ) -> RouteResponse:
        vehicle = VehicleOut.model_validate(load_owned(db, data.vehicle_id, user))
        router_: Router = request.app.state.router
        try:
            route = router_.route(data.origin, data.destination, vehicle)
        except NoRouteFound as exc:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY,
                "Brak trasy, którą ten pojazd może przejechać między tymi punktami.",
            ) from exc
        except RoutingUnavailable as exc:
            raise HTTPException(
                status.HTTP_503_SERVICE_UNAVAILABLE, "Serwer wyznaczania tras jest niedostępny."
            ) from exc
        return RouteResponse(**route.model_dump(), vehicle=vehicle)

    return router
