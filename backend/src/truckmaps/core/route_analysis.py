"""Ocena trasy dla pojazdu w pięciu poziomach, z powodami.

czerwony     – nie przejedzie (ograniczenie mniejsze niż pojazd, zakaz wjazdu)
pomarańczowy – prawie nie do przejechania tym pojazdem (osiedlówki dla zestawu, zapas < 10 cm)
żółty        – trudne miejsce (ciasny zakręt, mały zapas, drogi lokalne)
jasnozielony – rondo
zielony      – bez uwag

Wejście to punkty trasy, odcinki z Valhalli (z identyfikatorami dróg OSM) i
ograniczenia z bazy. Funkcje są czyste – bez bazy i sieci – więc łatwo je testować.
"""

import math
from collections import defaultdict
from dataclasses import dataclass
from enum import IntEnum

from pydantic import BaseModel

from truckmaps.core.restrictions import (
    ROAD_CONTEXT,
    Kind,
    Restriction,
    distance_m,
    parse_length,
)
from truckmaps.core.vehicles import VehicleIn

# Zapas do zmierzonego prześwitu (maxheight:physical, maxwidth:physical) bez znaku – poniżej
# tej wartości miejsce jest pomarańczowe i omijane. Wartość ze znaku jest dopuszczalna bez zapasu.
MEASURED_MARGIN_M = {
    Kind.HEIGHT: 0.20,
    Kind.WIDTH: 0.30,
}

# Wartości spoza tych zakresów to prawie na pewno błędy w danych (np. 615 m wysokości).
PLAUSIBLE = {
    Kind.HEIGHT: (1.5, 7.0),
    Kind.WIDTH: (1.0, 8.0),
    Kind.LENGTH: (3.0, 60.0),
    Kind.WEIGHT: (1.0, 100.0),
    Kind.WEIGHT_RATING: (1.0, 100.0),
    Kind.AXLE_LOAD: (1.0, 25.0),
}

LONG_VEHICLE_M = 12.0
MEDIUM_VEHICLE_M = 8.0
# Szerokość jezdni z OSM (tag width): od tej wartości dwa zestawy mijają się bez problemu,
# poniżej drugiej nawet w strefie przemysłowej jest ciasno.
WIDE_ROAD_M = 6.0
NARROW_ROAD_M = 4.5
NARROW_USES = {"living_street", "track", "driveway", "alley", "parking_aisle", "drive_through"}
MINOR_CLASSES = {"residential", "service_other"}
# Ulica z kilkoma pasami w kierunku jazdy nie jest ciasna, nawet gdy w danych jest osiedlowa.
WIDE_LANES = 2
# Dojazd do startu i celu: kierowca i tak musi tamtędy przejechać, więc ulica osiedlowa jest
# tu tylko żółta. Strefa zamieszkania (living_street) zostaje pomarańczowa.
END_ZONE_M = 1000.0
END_STREET = "Dojazd ulicą osiedlową / dojazdową – trudny dla zestawu"
BEND_SPACING_M = 10.0
NODE_MATCH_M = 4.0


class Level(IntEnum):
    GREEN = 0
    LIME = 1
    YELLOW = 2
    ORANGE = 3
    RED = 4

    @property
    def label(self) -> str:
        return ("green", "lime", "yellow", "orange", "red")[self]


# Wynik trasy (im mniej, tym lepiej): kara za każdy metr na danym poziomie i za każde
# osobne trudne miejsce. Służy do wyboru najlepszego wariantu trasy.
SCORE_PER_M = {
    Level.GREEN: 0.0,
    Level.LIME: 0.02,
    Level.YELLOW: 0.3,
    Level.ORANGE: 10.0,
    Level.RED: 1000.0,
}
SCORE_PER_WARNING = {
    Level.GREEN: 0,
    Level.LIME: 5,
    Level.YELLOW: 50,
    Level.ORANGE: 2000,
    Level.RED: 100_000,
}


class RouteEdge(BaseModel):
    way_id: int
    begin_index: int
    end_index: int
    road_class: str = ""
    use: str = ""
    lane_count: int | None = None
    roundabout: bool = False
    names: list[str] = []


class Segment(BaseModel):
    start_index: int
    end_index: int
    level: str


class RouteWarning(BaseModel):
    level: str
    kind: str
    message: str
    index: int
    end_index: int
    lon: float
    lat: float
    km: float
    limit: str | None = None
    """Wartość ograniczenia do znaku na mapie, np. "4,05 m", "30 t", "zakaz"."""


class Analysis(BaseModel):
    level: str
    score: float
    segments: list[Segment]
    warnings: list[RouteWarning]


@dataclass
class _Finding:
    level: Level
    kind: str
    message: str
    start: int
    end: int
    key: object = None
    """Ten sam klucz w sąsiednich odcinkach → jedno ostrzeżenie (np. długi wiadukt)."""
    value: float | None = None
    """Przy scalaniu zostaje komunikat z najmniejszą wartością (np. najciaśniejszy łuk)."""
    limit: str | None = None


def analyze(
    points: list[tuple[float, float]],
    edges: list[RouteEdge],
    vehicle: VehicleIn,
    way_restrictions: dict[int, list[Restriction]],
    node_restrictions: list[Restriction],
) -> Analysis:
    findings: list[_Finding] = []
    cumulative = _cumulative_m(points)
    total = cumulative[-1]
    for edge in edges:
        last = min(edge.end_index, len(cumulative) - 1)
        near_end = (
            cumulative[min(edge.begin_index, last)] < END_ZONE_M
            or cumulative[last] > total - END_ZONE_M
        )
        findings += _edge_findings(edge, vehicle, way_restrictions.get(edge.way_id, []), near_end)
    findings += _bend_findings(points, edges, vehicle)
    findings += _node_findings(points, node_restrictions, vehicle)
    return _summarize(points, findings)


def _edge_findings(
    edge: RouteEdge, vehicle: VehicleIn, restrictions: list[Restriction], near_end: bool = False
):
    span = (edge.begin_index, edge.end_index)
    name = f" ({edge.names[0]})" if edge.names else ""
    context: dict[Kind, Restriction] = {}
    for restriction in restrictions:
        if restriction.kind in ROAD_CONTEXT:
            context[Kind(restriction.kind)] = restriction
            continue
        finding = _compare(restriction, vehicle)
        if finding:
            level, message = finding
            yield _Finding(
                level,
                restriction.kind,
                message + name,
                *span,
                key=restriction.raw,
                limit=_limit_label(restriction),
            )

    road = _road_level(edge, vehicle, context, near_end)
    if road:
        level, message = road
        yield _Finding(level, "narrow", message + name, *span, key=("narrow", level))
    if Kind.BAD_SURFACE in context:
        yield _Finding(Level.YELLOW, "surface", f"Zła nawierzchnia{name}", *span, key="surface")
    if edge.roundabout:
        yield _Finding(Level.LIME, "roundabout", f"Rondo{name}", *span, key="roundabout")


def _road_level(
    edge: RouteEdge, vehicle: VehicleIn, context: dict[Kind, Restriction], near_end: bool = False
) -> tuple[Level, str] | None:
    """Ulice osiedlowe, dojazdowe i lokalne – im dłuższy pojazd, tym trudniej.

    Otoczenie i cechy drogi łagodzą ocenę: drogi oznaczone dla ciężarówek, szerokie albo
    z kilkoma pasami nie są problemem, a w strefach przemysłowych drogi "osiedlowe" są
    zwykle szerokie. Przy starcie i celu (``near_end``) ulica osiedlowa jest tylko żółta.
    """
    length = vehicle.length_m
    width = context[Kind.ROAD_WIDTH].value if Kind.ROAD_WIDTH in context else None
    if Kind.HGV_DESIGNATED in context or (width is not None and width >= WIDE_ROAD_M):
        return None
    if (edge.lane_count or 0) >= WIDE_LANES:
        return None
    if edge.use in NARROW_USES or edge.road_class in MINOR_CLASSES:
        if Kind.INDUSTRIAL_AREA in context and (width is None or width >= NARROW_ROAD_M):
            if length > MEDIUM_VEHICLE_M:
                return Level.YELLOW, "Droga dojazdowa w strefie przemysłowej"
            return None
        if length > LONG_VEHICLE_M and near_end and edge.use != "living_street":
            return Level.YELLOW, END_STREET
        if length > LONG_VEHICLE_M:
            return Level.ORANGE, "Ulica osiedlowa / dojazdowa – bardzo trudna dla zestawu"
        if length > MEDIUM_VEHICLE_M or edge.use in NARROW_USES:
            return Level.YELLOW, "Wąska ulica osiedlowa / dojazdowa"
        return None
    if edge.road_class == "unclassified" and length > LONG_VEHICLE_M:
        return Level.YELLOW, "Droga lokalna – możliwe zwężenia"
    return None


def _compare(restriction: Restriction, vehicle: VehicleIn) -> tuple[Level, str] | None:
    kind, value = Kind(restriction.kind), restriction.value
    if kind in (Kind.HGV_NO, Kind.HGV_DESTINATION) and not vehicle.is_hgv:
        return None  # zakazy dla ciężarówek nie dotyczą pojazdów o DMC do 3,5 t
    if kind is Kind.HGV_NO:
        return Level.RED, "Zakaz wjazdu ciężarówek (DMC powyżej 3,5 t)"
    if kind is Kind.HGV_DESTINATION:
        return Level.YELLOW, "Ciężarówki tylko dojazd"
    if value is None or not PLAUSIBLE[kind][0] <= value <= PLAUSIBLE[kind][1]:
        return None
    if kind in (Kind.WEIGHT, Kind.WEIGHT_RATING, Kind.AXLE_LOAD):
        actual, what, label = {
            Kind.WEIGHT: (vehicle.weight_t, "Ograniczenie masy rzeczywistej", "pojazd"),
            Kind.WEIGHT_RATING: (vehicle.gvw_t, "Ograniczenie DMC", "DMC pojazdu"),
            Kind.AXLE_LOAD: (vehicle.axle_load_t, "Ograniczenie nacisku osi", "pojazd"),
        }[kind]
        if value < actual:
            return Level.RED, f"{what} {_num(value)} t, {label} {_num(actual)} t"
        return None
    actual, what = {
        Kind.HEIGHT: (vehicle.height_m, "Ograniczenie wysokości"),
        Kind.WIDTH: (vehicle.width_m, "Ograniczenie szerokości"),
        Kind.LENGTH: (vehicle.length_m, "Ograniczenie długości"),
    }[kind]
    # Znak: wartość dopuszczalna – pojazd 4,0 m pod znakiem 4,0 m jedzie (znak stawia się
    # z zapasem względem prześwitu), wyższy nie może wjechać, nawet jeśli by się zmieścił.
    measured = ":physical" in restriction.raw
    sign = _sign_value(restriction.raw) if measured else value
    if sign is not None and actual > sign:
        return Level.RED, f"{what} {_num(sign)} m (znak), pojazd {_num(actual)} m"
    if not measured:
        return None
    # Do milimetra: 4,1 − 4,0 w liczbach zmiennoprzecinkowych to 0,0999…, nie 0,1.
    spare = round(value - actual, 3)
    if spare < 0:
        return Level.RED, f"{what} {_num(value)} m (pomiar), pojazd {_num(actual)} m"
    if sign is not None:
        return None  # znak dopuszcza pojazd, a pomiar go mieści
    # Sam pomiar bez znaku: mały zapas = bardzo trudne miejsce, więc planer szuka objazdu.
    if spare < MEASURED_MARGIN_M[kind]:
        return (
            Level.ORANGE,
            f"{what} {_num(value)} m (pomiar, bez znaku) – zapas tylko {round(spare * 100)} cm",
        )
    return None


def _limit_label(restriction: Restriction) -> str | None:
    """Wartość do znaku na mapie, np. "4,05 m", "30 t"."""
    kind, value = Kind(restriction.kind), restriction.value
    if kind is Kind.HGV_NO:
        return "zakaz"
    if value is None:
        return None
    unit = "m" if kind in (Kind.HEIGHT, Kind.WIDTH, Kind.LENGTH) else "t"
    return f"{_num(value)} {unit}"


def _sign_value(raw: str) -> float | None:
    """Wartość ze znaku zapisana obok pomiaru, np. "maxheight:physical=4.15;maxheight=4"."""
    for part in raw.split(";"):
        key, _, value = part.partition("=")
        if key.startswith("max") and ":physical" not in key:
            return parse_length(value)
    return None


def _bend_findings(points, edges: list[RouteEdge], vehicle: VehicleIn):
    """Ostre łuki wewnątrz dróg (skręty na skrzyżowaniach to manewry; ronda oceniane osobno)."""
    yellow_radius = min(max(0.9 * vehicle.length_m, 8.0), 20.0)
    orange_radius = min(max(0.6 * vehicle.length_m, 6.0), 12.0)
    junctions = {e.begin_index for e in edges} | {e.end_index for e in edges}
    in_roundabout = {
        i for e in edges if e.roundabout for i in range(e.begin_index, e.end_index + 1)
    }
    cumulative = _cumulative_m(points)
    for i in range(1, len(points) - 1):
        if i in junctions or i in in_roundabout:
            continue
        before = _point_at_distance(points, cumulative, i, -BEND_SPACING_M)
        after = _point_at_distance(points, cumulative, i, BEND_SPACING_M)
        if before is None or after is None:
            continue
        radius = _circle_radius(points[before], points[i], points[after])
        if radius < yellow_radius:
            orange = radius < orange_radius
            yield _Finding(
                Level.ORANGE if orange else Level.YELLOW,
                "bend",
                f"{'Bardzo ostry' if orange else 'Ostry'} zakręt – promień ok. {round(radius)} m",
                before,
                after,
                key="bend",
                value=radius,
            )


def _node_findings(points, nodes: list[Restriction], vehicle: VehicleIn):
    """Ograniczenia punktowe (np. bramki wysokości) leżące na linii trasy – tylko ostrzeżenie."""
    grid = _SegmentGrid(points)
    for node in nodes:
        if node.kind not in (Kind.HEIGHT, Kind.WEIGHT, Kind.WEIGHT_RATING) or node.lat is None:
            continue
        index = grid.nearest(node.lon, node.lat, NODE_MATCH_M)
        if index is None:
            continue
        finding = _compare(node, vehicle)
        if finding:
            _, message = finding
            yield _Finding(
                Level.YELLOW,
                node.kind,
                f"{message} – punkt przy trasie, sprawdź",
                index,
                index + 1,
                limit=_limit_label(node),
            )


def _summarize(points, findings: list[_Finding]) -> Analysis:
    n = max(len(points) - 1, 0)
    levels = [Level.GREEN] * n
    for finding in findings:
        for i in range(finding.start, min(finding.end, n)):
            levels[i] = max(levels[i], finding.level)

    cumulative = _cumulative_m(points)
    segments: list[Segment] = []
    score = 0.0
    for i, level in enumerate(levels):
        score += (cumulative[i + 1] - cumulative[i]) * SCORE_PER_M[level]
        if segments and segments[-1].level == level.label:
            segments[-1].end_index = i + 1
        else:
            segments.append(Segment(start_index=i, end_index=i + 1, level=level.label))

    warnings: list[RouteWarning] = []
    open_groups: dict[tuple, tuple[_Finding, RouteWarning]] = {}
    last = max(len(points) - 1, 0)
    for finding in sorted(findings, key=lambda f: (f.start, -f.level)):
        # Sąsiednie odcinki z tym samym problemem (długi wiadukt, kilka łuków jednego
        # zakrętu, ciąg osiedlowych uliczek) → jedno ostrzeżenie.
        group = (finding.kind, finding.key if finding.key is not None else finding.message)
        current = open_groups.get(group)
        if current and current[1].end_index >= finding.start - 1:
            first, warning = current
            warning.end_index = max(warning.end_index, min(finding.end, last))
            if finding.value is not None and (first.value is None or finding.value < first.value):
                warning.message = finding.message
                open_groups[group] = (finding, warning)
            continue
        start = min(finding.start, last)
        lon, lat = points[start]
        warning = RouteWarning(
            level=finding.level.label,
            kind=finding.kind,
            message=finding.message,
            index=start,
            end_index=min(finding.end, last),
            lon=lon,
            lat=lat,
            km=round(cumulative[start] / 1000, 1),
            limit=finding.limit,
        )
        warnings.append(warning)
        open_groups[group] = (finding, warning)
        score += SCORE_PER_WARNING[finding.level]
    overall = max((f.level for f in findings), default=Level.GREEN)
    return Analysis(
        level=overall.label, score=round(score, 1), segments=segments, warnings=warnings
    )


def _num(value: float) -> str:
    return f"{value:.2f}".rstrip("0").rstrip(".").replace(".", ",")


def _cumulative_m(points) -> list[float]:
    total, result = 0.0, [0.0]
    for (lon1, lat1), (lon2, lat2) in zip(points, points[1:], strict=False):
        total += distance_m(lon1, lat1, lon2, lat2)
        result.append(total)
    return result


def _point_at_distance(points, cumulative, index: int, offset: float) -> int | None:
    target = cumulative[index] + offset
    step = 1 if offset > 0 else -1
    j = index
    while 0 <= j + step < len(points):
        j += step
        if (cumulative[j] >= target) if offset > 0 else (cumulative[j] <= target):
            return j
    return None


def _circle_radius(a, b, c) -> float:
    """Promień okręgu przez trzy punkty (w metrach); prosta → nieskończoność."""
    ab = distance_m(*a, *b)
    bc = distance_m(*b, *c)
    ca = distance_m(*c, *a)
    s = (ab + bc + ca) / 2
    area = math.sqrt(max(s * (s - ab) * (s - bc) * (s - ca), 0.0))
    if area < 1e-6:
        return math.inf
    return ab * bc * ca / (4 * area)


class _SegmentGrid:
    """Siatka ~100 m na odcinki trasy – szybkie szukanie odcinka najbliższego punktowi."""

    CELL = 0.001

    def __init__(self, points, cell: float = CELL) -> None:
        """``cell`` w stopniach; szukanie obejmuje sąsiednie komórki, więc ``max_m`` < komórki."""
        self.cell = cell
        self.points = points
        self.cells: dict[tuple[int, int], list[int]] = defaultdict(list)
        for i, ((lon1, lat1), (lon2, lat2)) in enumerate(zip(points, points[1:], strict=False)):
            for cx in range(self._c(min(lon1, lon2)), self._c(max(lon1, lon2)) + 1):
                for cy in range(self._c(min(lat1, lat2)), self._c(max(lat1, lat2)) + 1):
                    self.cells[(cx, cy)].append(i)

    def _c(self, value: float) -> int:
        return math.floor(value / self.cell)

    def nearest(self, lon: float, lat: float, max_m: float) -> int | None:
        best, best_index = max_m, None
        cx, cy = self._c(lon), self._c(lat)
        candidates = {
            i
            for dx in (-1, 0, 1)
            for dy in (-1, 0, 1)
            for i in self.cells.get((cx + dx, cy + dy), ())
        }
        for i in candidates:
            distance = _distance_to_segment(lon, lat, self.points[i], self.points[i + 1])
            if distance <= best:
                best, best_index = distance, i
        return best_index


def _distance_to_segment(lon: float, lat: float, a, b) -> float:
    scale = math.cos(math.radians(lat))
    px, py = (lon - a[0]) * scale, lat - a[1]
    dx, dy = (b[0] - a[0]) * scale, b[1] - a[1]
    length2 = dx * dx + dy * dy
    t = 0.0 if length2 == 0 else max(0.0, min(1.0, (px * dx + py * dy) / length2))
    nearest_lon = a[0] + t * (b[0] - a[0])
    nearest_lat = a[1] + t * (b[1] - a[1])
    return distance_m(lon, lat, nearest_lon, nearest_lat)
