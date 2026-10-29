"""Polilinie w formacie Valhalli / Google z precyzją 1e-6 (kształty tras i dróg)."""


def encode_polyline6(points: list[tuple[float, float]]) -> str:
    """Koduje listę [lon, lat] do tekstu (kilka bajtów na punkt zamiast kilkudziesięciu)."""
    out: list[str] = []
    last_lat = last_lon = 0
    for lon, lat in points:
        lat_i, lon_i = round(lat * 1e6), round(lon * 1e6)
        for delta in (lat_i - last_lat, lon_i - last_lon):
            value = ~(delta << 1) if delta < 0 else delta << 1
            while value >= 0x20:
                out.append(chr((0x20 | (value & 0x1F)) + 63))
                value >>= 5
            out.append(chr(value + 63))
        last_lat, last_lon = lat_i, lon_i
    return "".join(out)


def decode_polyline6(encoded: str) -> list[tuple[float, float]]:
    """Dekoduje polilinię (precyzja 1e-6) do listy [lon, lat]."""
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
