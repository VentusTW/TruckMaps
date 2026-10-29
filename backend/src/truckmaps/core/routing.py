"""Wyznaczanie trasy dla ciężarówki (Valhalla, koszt ``truck``) z omijaniem trudnych miejsc."""

from typing import Annotated, Literal, Protocol

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from truckmaps.core import costs, parkings, restrictions
from truckmaps.core.companies import Company
from truckmaps.core.db import get_session
from truckmaps.core.restrictions import distance_m
from truckmaps.core.route_analysis import Analysis, Level, RouteEdge, RouteWarning, analyze
from truckmaps.core.vehicles import VehicleIn, VehicleOut, load_owned
from truckmaps.sdk import Principal

# Kody Valhalli: 442 – "No path could be found", 171 – "No suitable edges near location".
VALHALLA_NO_ROUTE = {442, 171}
EDGE_ATTRIBUTES = [
    "edge.way_id",
    "edge.begin_shape_index",
    "edge.end_shape_index",
    "edge.road_class",
    "edge.use",
    "edge.lane_count",
    "edge.roundabout",
    "edge.names",
]

# Omijanie trudnych miejsc: ile razy przeliczać trasę i jak długi objazd jest rozsądny.
AVOID_ROUNDS = 3
MAX_DETOUR_FACTOR = 1.25
MAX_DETOUR_EXTRA_KM = 3.0
# Miejsc przy starcie, celu i punktach pośrednich nie omijamy – tam trzeba dojechać.
KEEP_NEAR_STOPS_M = 400.0
AVOID_LEVELS = {Level.ORANGE.label, Level.RED.label}
# Miejsc, których pojazd nie przejedzie, trasa nie może zawierać – omijane zawsze, bez limitu
# objazdu i także przy wyłączonym omijaniu trudnych dróg.
IMPASSABLE = Level.RED.label
# Ile tras alternatywnych pokazać i kiedy dwie trasy uznać za tę samą.
MAX_ALTERNATIVES = 2
SAME_ROUTE_KM = 0.3
SAME_ROUTE_MIN = 1.0
# Alternatywa dużo dłuższa od trasy głównej nie jest realnym wyborem.
MAX_ALTERNATIVE_FACTOR = 1.2
MAX_ALTERNATIVE_EXTRA_KM = 5.0
# Punkt dalej niż tyle od najbliższej drogi dostępnej dla pojazdu – nie da się do niego dojechać.
UNREACHABLE_M = 40.0
# Trudne miejsca tak blisko startu lub celu oznaczają trudny dojazd – podpowiadamy parking.
DIFFICULT_END_M = 300.0
PARKING_RADIUS_M = 20000.0


class Point(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)


class RouteRequest(BaseModel):
    origin: Point
    destination: Point
    via: list[Point] = Field(default=[], max_length=20, description="Punkty pośrednie, po kolei")
    vehicle_id: str
    avoid_difficult: bool = Field(
        default=True, description="Omijaj miejsca pomarańczowe i czerwone, jeśli jest objazd"
    )


class Route(BaseModel):
    distance_km: float
    duration_min: float
    geometry: list[tuple[float, float]] = Field(description="Punkty trasy jako [lon, lat]")
    edges: list[RouteEdge] | None = Field(default=None, exclude=True)
    """Odcinki z identyfikatorami dróg OSM; ``None``, gdy Valhalla ich nie zwróciła."""
    alternates: list["Route"] = Field(default=[], exclude=True)
    """Alternatywy silnika tras (tylko dla trasy bez punktów pośrednich)."""


class AlternativeRoute(BaseModel):
    distance_km: float
    duration_min: float
    geometry: list[tuple[float, float]]
    analysis: Analysis | None
    cost: costs.RouteCost | None = None


class ParkingOut(BaseModel):
    name: str | None
    kind: str
    kind_label: str
    lat: float
    lon: float
    distance_m: float
    hgv_capacity: int | None


class StopIssue(BaseModel):
    role: Literal["origin", "via", "destination"]
    index: int = Field(description="Numer punktu pośredniego (od 1); 0 dla startu i celu")
    kind: Literal["unreachable", "difficult"]
    message: str
    requested: Point
    reachable: Point | None = Field(description="Najbliższe miejsce dostępne dla pojazdu")
    distance_m: float | None
    parkings: list[ParkingOut] = []


class RouteResponse(Route):
    vehicle: VehicleOut
    analysis: Analysis | None = Field(
        description="Ocena trasy dla pojazdu; brak, gdy nie udało się pobrać odcinków"
    )
    avoided: list[Point] = Field(default=[], description="Miejsca ominięte przy planowaniu")
    avoided_warnings: list[RouteWarning] = Field(
        default=[],
        description="Trudne miejsca, które planer ominął (do pokazania na mapie obok objazdu)",
    )
    base_distance_km: float = Field(description="Długość trasy przed omijaniem trudnych miejsc")
    alternatives: list[AlternativeRoute] = Field(
        default=[], description="Do dwóch innych wariantów, od najmniej problematycznego"
    )
    stop_issues: list[StopIssue] = Field(
        default=[], description="Punkty, do których pojazd nie dojedzie lub dojazd jest trudny"
    )
    cost: costs.RouteCost | None = Field(
        default=None, description="Szacunkowy koszt; brak, gdy pojazd ani firma nie mają stawek"
    )


class NoRouteFound(Exception):
    pass


class ImpassableRoute(NoRouteFound):
    """Każdy znaleziony wariant przechodzi przez miejsce, którego pojazd nie przejedzie."""

    def __init__(self, warnings: list[RouteWarning]) -> None:
        super().__init__(", ".join(w.message for w in warnings))
        self.warnings = warnings


class RoutingUnavailable(Exception):
    pass


class Router(Protocol):
    def route(
        self,
        stops: list[Point],
        vehicle: VehicleIn,
        exclude: list[Point] | None = None,
        alternates: int = 0,
    ) -> Route:
        """Trasa przez kolejne punkty (start, pośrednie, cel), bez dróg przy ``exclude``.

        ``alternates`` – ile tras alternatywnych dołączyć w ``Route.alternates``.
        """
        ...

    def locate(self, stops: list[Point], vehicle: VehicleIn) -> list[tuple[Point, float] | None]:
        """Najbliższe miejsce na drodze dostępnej dla pojazdu i odległość do niego (m).

        ``None`` – w pobliżu nie ma takiej drogi. Pusta lista – sprawdzenie niedostępne.
        """
        ...


class ValhallaRouter:
    def __init__(self, url: str, http: httpx.Client | None = None) -> None:
        self._url = url.rstrip("/")
        self._http = http or httpx.Client(timeout=60)

    def route(
        self,
        stops: list[Point],
        vehicle: VehicleIn,
        exclude: list[Point] | None = None,
        alternates: int = 0,
    ) -> Route:
        last = len(stops) - 1
        locations = [
            # Punkty pośrednie typu "through": bez zatrzymania i zawracania.
            {"lat": p.lat, "lon": p.lon, "type": "break" if i in (0, last) else "through"}
            for i, p in enumerate(stops)
        ]
        request = {
            "locations": locations,
            "costing": "truck",
            "costing_options": {"truck": truck_options(vehicle)},
            "units": "kilometers",
            "directions_type": "none",
        }
        if exclude:
            request["exclude_locations"] = [{"lat": p.lat, "lon": p.lon} for p in exclude]
        if alternates and len(stops) == 2:
            # Valhalla liczy alternatywy tylko dla trasy z dwoma punktami.
            request["alternates"] = alternates
        try:
            response = self._http.post(f"{self._url}/route", json=request)
        except httpx.HTTPError as exc:
            raise RoutingUnavailable(str(exc)) from exc
        body = response.json() if response.content else {}
        if response.status_code == 400 and body.get("error_code") in VALHALLA_NO_ROUTE:
            raise NoRouteFound(body.get("error", ""))
        if response.is_error:
            raise RoutingUnavailable(f"Valhalla {response.status_code}: {body.get('error')}")

        route = self._parse_trip(body["trip"], vehicle)
        route.alternates = [
            self._parse_trip(alternate["trip"], vehicle) for alternate in body.get("alternates", [])
        ]
        return route

    def locate(self, stops: list[Point], vehicle: VehicleIn) -> list[tuple[Point, float] | None]:
        request = {
            "locations": [{"lat": p.lat, "lon": p.lon} for p in stops],
            "costing": "truck",
            "costing_options": {"truck": truck_options(vehicle)},
            "verbose": True,
        }
        try:
            response = self._http.post(f"{self._url}/locate", json=request)
            response.raise_for_status()
            located = []
            for location in response.json():
                edges = location.get("edges") or []
                if not edges:
                    located.append(None)
                    continue
                nearest = min(edges, key=lambda e: e.get("distance", 0.0))
                point = Point(lat=nearest["correlated_lat"], lon=nearest["correlated_lon"])
                located.append((point, float(nearest.get("distance", 0.0))))
            return located
        except (httpx.HTTPError, ValueError, KeyError):
            return []

    def _parse_trip(self, trip: dict, vehicle: VehicleIn) -> Route:
        geometry: list[tuple[float, float]] = []
        edges: list[RouteEdge] | None = []
        for leg in trip["legs"]:
            offset = len(geometry)
            matched = self._edges(leg["shape"], vehicle)
            if matched is None:
                geometry += decode_polyline6(leg["shape"])
                edges = None
            else:
                leg_edges, leg_shape = matched
                geometry += leg_shape
                if edges is not None:
                    edges += [
                        e.model_copy(
                            update={
                                "begin_index": e.begin_index + offset,
                                "end_index": e.end_index + offset,
                            }
                        )
                        for e in leg_edges
                    ]
        return Route(
            distance_km=round(trip["summary"]["length"], 1),
            duration_min=round(trip["summary"]["time"] / 60, 1),
            geometry=geometry,
            edges=edges,
        )

    def _edges(
        self, shape: str, vehicle: VehicleIn
    ) -> tuple[list[RouteEdge], list[tuple[float, float]]] | None:
        """Odcinki trasy z identyfikatorami dróg OSM (Valhalla ``trace_attributes``).

        Najpierw dokładne dopasowanie (``edge_walk``) do linii trasy. Gdy trasa przechodzi
        przez punkt pośredni w środku drogi, Valhalla go nie znajduje (błąd 443) – wtedy
        dopasowanie do mapy (``map_snap``), które zwraca własną, wyrównaną linię trasy.
        Indeksy odcinków odnoszą się zawsze do zwróconej linii.
        """
        for shape_match in ("edge_walk", "map_snap"):
            result = self._trace(shape, shape_match, vehicle)
            if result is not None:
                return result
        return None

    def _trace(
        self, shape: str, shape_match: str, vehicle: VehicleIn
    ) -> tuple[list[RouteEdge], list[tuple[float, float]]] | None:
        request = {
            "encoded_polyline": shape,
            "shape_match": shape_match,
            "costing": "truck",
            "costing_options": {"truck": truck_options(vehicle)},
            "filters": {"attributes": [*EDGE_ATTRIBUTES, "shape"], "action": "include"},
        }
        try:
            response = self._http.post(f"{self._url}/trace_attributes", json=request)
            response.raise_for_status()
            body = response.json()
            matched_shape = decode_polyline6(body.get("shape") or shape)
            edges = [
                RouteEdge(
                    way_id=edge["way_id"],
                    begin_index=edge["begin_shape_index"],
                    end_index=edge["end_shape_index"],
                    road_class=edge.get("road_class", ""),
                    use=edge.get("use", ""),
                    lane_count=edge.get("lane_count"),
                    roundabout=edge.get("roundabout", False),
                    names=edge.get("names", []),
                )
                for edge in body.get("edges", [])
                if "way_id" in edge
            ]
        except (httpx.HTTPError, ValueError, KeyError):
            return None
        if not edges or max(e.end_index for e in edges) >= len(matched_shape):
            return None
        return edges, matched_shape


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
        # Ciężarówka nie powinna szukać skrótów przez strefy zamieszkania i drogi gruntowe.
        "use_living_streets": 0.0,
        "use_tracks": 0.0,
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


def plan(
    router: Router,
    db: Session,
    stops: list[Point],
    vehicle: VehicleIn,
    avoid_difficult: bool = True,
) -> tuple[Route, Analysis | None, list[Point], float, list[RouteWarning]]:
    """Trasa z jak najmniejszą liczbą trudnych miejsc (alternatywy – patrz ``alternatives``).

    Po wyznaczeniu trasy miejsca pomarańczowe i czerwone (poza okolicą startu, celu i
    punktów pośrednich) są wykluczane i trasa jest liczona ponownie. Wygrywa wariant o
    najniższym wyniku oceny, o ile objazd nie jest nierozsądnie długi. Miejsca czerwone
    (pojazd nie przejedzie) są omijane zawsze i bez limitu objazdu; gdy się nie da –
    ``ImpassableRoute`` zamiast trasy.
    Zwraca: trasę, jej ocenę, ominięte miejsca, długość pierwszej trasy i ominięte
    ostrzeżenia (czego unika objazd).
    """
    first = router.route(stops, vehicle, alternates=MAX_ALTERNATIVES)
    best, best_analysis, best_excluded = first, assess(db, first, vehicle), []
    if best_analysis is None:
        return best, best_analysis, best_excluded, first.distance_km, []
    levels = AVOID_LEVELS if avoid_difficult else {IMPASSABLE}
    difficult: list[RouteWarning] = []

    excluded: list[Point] = []
    max_km = first.distance_km * MAX_DETOUR_FACTOR + MAX_DETOUR_EXTRA_KM
    for _ in range(AVOID_ROUNDS):
        points = _avoid_points(best, best_analysis.warnings, stops, levels)
        if not points:
            break
        excluded += points
        try:
            candidate = router.route(stops, vehicle, exclude=excluded)
        except NoRouteFound:
            break
        analysis = assess(db, candidate, vehicle)
        if analysis is None or analysis.score >= best_analysis.score:
            break
        if candidate.distance_km > max_km and not _impassable(best_analysis):
            break
        difficult += [w for w in best_analysis.warnings if w.level in levels]
        best, best_analysis, best_excluded = candidate, analysis, list(excluded)
    if blocked := _impassable(best_analysis):
        raise ImpassableRoute(blocked)
    # Ominięte = trudne miejsca z wcześniejszych wariantów, których nie ma na wybranej trasie.
    remaining = {(w.kind, w.message) for w in best_analysis.warnings}
    avoided_warnings = list(
        {(w.kind, w.message): w for w in difficult if (w.kind, w.message) not in remaining}.values()
    )
    return best, best_analysis, best_excluded, first.distance_km, avoided_warnings


def alternatives(
    db: Session, chosen: Route, candidates: list[Route], vehicle: VehicleIn
) -> list[AlternativeRoute]:
    """Do dwóch tras innych niż wybrana, od najmniej problematycznej."""
    found: list[tuple[float, AlternativeRoute]] = []
    taken = [chosen]
    max_km = chosen.distance_km * MAX_ALTERNATIVE_FACTOR + MAX_ALTERNATIVE_EXTRA_KM
    for candidate in candidates:
        if candidate.distance_km > max_km or any(_same_route(candidate, o) for o in taken):
            continue
        taken.append(candidate)
        analysis = assess(db, candidate, vehicle)
        if analysis is not None and _impassable(analysis):
            continue  # alternatywa przez miejsce nieprzejezdne nie wchodzi w grę
        score = analysis.score if analysis else float("inf")
        found.append(
            (
                score,
                AlternativeRoute(
                    distance_km=candidate.distance_km,
                    duration_min=candidate.duration_min,
                    geometry=candidate.geometry,
                    analysis=analysis,
                ),
            )
        )
    found.sort(key=lambda item: (item[0], item[1].duration_min))
    return [alternative for _, alternative in found[:MAX_ALTERNATIVES]]


def _same_route(a: Route, b: Route) -> bool:
    return (
        abs(a.distance_km - b.distance_km) < SAME_ROUTE_KM
        and abs(a.duration_min - b.duration_min) < SAME_ROUTE_MIN
    )


def check_stops(
    router: Router, db: Session, stops: list[Point], vehicle: VehicleIn
) -> list[StopIssue]:
    """Punkty, do których ten pojazd nie dojedzie – z najbliższym dostępnym miejscem."""
    located = router.locate(stops, vehicle)
    if len(located) != len(stops):
        return []
    issues = []
    last = len(stops) - 1
    for i, (stop, found) in enumerate(zip(stops, located, strict=True)):
        if found is not None and found[1] <= UNREACHABLE_M:
            continue
        role = "origin" if i == 0 else "destination" if i == last else "via"
        reachable, distance = found if found else (None, None)
        where = (
            f" najbliższa droga dostępna dla niego jest {round(distance)} m dalej"
            if found
            else (" w pobliżu nie ma drogi dostępnej dla niego")
        )
        if role == "via":
            message = (
                f"Przez punkt pośredni nr {i} nie da się przejechać tym pojazdem –{where}. "
                "Przesuń punkt albo usuń go prawym przyciskiem myszy."
            )
        else:
            target = "punktu startu" if role == "origin" else "celu"
            message = f"Ten pojazd nie dojedzie do {target} –{where}. Zaznaczono je na mapie."
        issues.append(
            StopIssue(
                role=role,
                index=i if role == "via" else 0,
                kind="unreachable",
                message=message,
                requested=stop,
                reachable=reachable,
                distance_m=round(distance, 1) if distance is not None else None,
                parkings=_parkings(db, stop) if role != "via" else [],
            )
        )
    return issues


def difficult_ends(
    db: Session,
    route: Route,
    analysis: Analysis | None,
    stops: list[Point],
    already: list[StopIssue],
) -> list[StopIssue]:
    """Trudny dojazd tuż przy starcie lub celu (pomarańczowy, czerwony) – podpowiedź parkingu."""
    if analysis is None:
        return []
    total_m = route.distance_km * 1000
    flagged = {issue.role for issue in already}
    issues = []
    for role, stop in (("origin", stops[0]), ("destination", stops[-1])):
        if role in flagged:
            continue
        near_end = [
            w
            for w in analysis.warnings
            if w.level in AVOID_LEVELS
            and (
                w.km * 1000 <= DIFFICULT_END_M
                if role == "origin"
                else total_m - w.km * 1000 <= DIFFICULT_END_M
            )
        ]
        if not near_end:
            continue
        target = "ze startu" if role == "origin" else "do celu"
        issues.append(
            StopIssue(
                role=role,
                index=0,
                kind="difficult",
                message=f"Trudny dojazd {target} dla tego pojazdu: {near_end[0].message}. "
                "Rozważ parking dla ciężarówek w pobliżu.",
                requested=stop,
                reachable=None,
                distance_m=None,
                parkings=_parkings(db, stop),
            )
        )
    return issues


def _parkings(db: Session, stop: Point) -> list[ParkingOut]:
    return [
        ParkingOut(
            name=parking.name,
            kind=parking.kind,
            kind_label=parkings.PARKING_KINDS.get(parking.kind, parking.kind),
            lat=parking.lat,
            lon=parking.lon,
            distance_m=round(distance),
            hgv_capacity=parking.hgv_capacity,
        )
        for parking, distance in parkings.nearest(db, stop.lat, stop.lon, PARKING_RADIUS_M)
    ]


def assess(db: Session, route: Route, vehicle: VehicleIn) -> Analysis | None:
    if route.edges is None:
        return None
    return analyze(
        route.geometry,
        route.edges,
        vehicle,
        restrictions.for_ways(db, (e.way_id for e in route.edges)),
        restrictions.nodes_in_bbox(db, route.geometry),
    )


def _avoid_points(
    route: Route, warnings: list[RouteWarning], stops: list[Point], levels: set[str]
) -> list[Point]:
    """Punkty na trudnych odcinkach, które Valhalla ma ominąć (kilka na długi odcinek).

    Trudne miejsca przy starcie, celu i punktach pośrednich zostają (tam trzeba dojechać),
    nieprzejezdne – nie.
    """
    points = []
    for warning in warnings:
        if warning.level not in levels:
            continue
        span = list(range(warning.index, max(warning.end_index, warning.index + 1)))
        step = max(len(span) // 4, 1)
        for i in span[step // 2 :: step][:4]:
            lon, lat = route.geometry[i]
            near_stop = any(distance_m(lon, lat, s.lon, s.lat) < KEEP_NEAR_STOPS_M for s in stops)
            if warning.level == IMPASSABLE or not near_stop:
                points.append(Point(lat=lat, lon=lon))
    return points


def _impassable(analysis: Analysis) -> list[RouteWarning]:
    return [w for w in analysis.warnings if w.level == IMPASSABLE]


class _Recording:
    """Router zapamiętujący wszystkie policzone warianty – kandydaci na trasy alternatywne."""

    def __init__(self, inner: Router, seen: list[Route]) -> None:
        self._inner = inner
        self._seen = seen

    def route(self, stops, vehicle, exclude=None, alternates=0) -> Route:
        route = self._inner.route(stops, vehicle, exclude=exclude, alternates=alternates)
        self._seen += [route, *route.alternates]
        return route

    def locate(self, stops, vehicle):
        return self._inner.locate(stops, vehicle)


def build_router(current_user) -> APIRouter:
    router = APIRouter(prefix="/api/routes", tags=["routes"])

    @router.post("")
    def calculate_route(
        data: RouteRequest,
        request: Request,
        user: Annotated[Principal, Depends(current_user)],
        db: Annotated[Session, Depends(get_session)],
    ) -> RouteResponse:
        profile = load_owned(db, data.vehicle_id, user)
        vehicle = VehicleOut.model_validate(profile)
        company = db.get(Company, profile.company_id) if profile.company_id else None
        rates = costs.rates_for(profile, company)
        stops = [data.origin, *data.via, data.destination]
        router_: Router = request.app.state.router
        issues = check_stops(router_, db, stops, vehicle)
        try:
            first_candidates: list[Route] = []
            route, analysis, avoided, base_km, avoided_warnings = plan(
                _Recording(router_, first_candidates),
                db,
                stops,
                vehicle,
                data.avoid_difficult,
            )
        except ImpassableRoute as exc:
            places = "; ".join(
                f"km {w.km:.1f}: {w.message}".replace(".", ",", 1) for w in exc.warnings
            )
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY,
                "Brak trasy dla tego pojazdu: każdy wariant przechodzi przez miejsce, którego "
                f"nie przejedzie ({places}). Sprawdź wymiary pojazdu albo wybierz inny cel.",
            ) from exc
        except NoRouteFound as exc:
            # Punkt tuż przy drodze, ale w strefie bez wjazdu dla ciężarówek (np. stare miasto):
            # sprawdzenie punktów go nie wychwyci, bo droga jest blisko.
            reasons = " ".join(issue.message for issue in issues) or (
                "Najpewniej start, cel albo punkt pośredni leży w strefie, do której ten pojazd "
                "nie wjedzie (np. stare miasto z zakazem dla ciężarówek). Przesuń punkt na "
                "pobliską drogę główną."
            )
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY,
                "Brak trasy, którą ten pojazd może przejechać między tymi punktami. " + reasons,
            ) from exc
        except RoutingUnavailable as exc:
            raise HTTPException(
                status.HTTP_503_SERVICE_UNAVAILABLE, "Serwer wyznaczania tras jest niedostępny."
            ) from exc
        extensions = request.app.state.extensions

        def cost(distance_km: float, duration_min: float) -> costs.RouteCost | None:
            return costs.estimate(extensions, rates, distance_km, duration_min)

        return RouteResponse(
            **route.model_dump(),
            vehicle=vehicle,
            analysis=analysis,
            avoided=avoided,
            avoided_warnings=avoided_warnings,
            base_distance_km=base_km,
            alternatives=[
                alt.model_copy(update={"cost": cost(alt.distance_km, alt.duration_min)})
                for alt in alternatives(db, route, first_candidates, vehicle)
            ],
            stop_issues=issues + difficult_ends(db, route, analysis, stops, issues),
            cost=cost(route.distance_km, route.duration_min),
        )

    return router
