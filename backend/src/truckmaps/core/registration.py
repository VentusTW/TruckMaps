"""Dane pojazdu z kodu Aztec polskiego dowodu rejestracyjnego.

Kod zawiera tekst Base64: 4 bajty długości (little-endian), potem dane skompresowane NRV2E
(biblioteka UCL), po rozpakowaniu tekst UTF-16LE z polami rozdzielonymi „|”.
Odczytujemy tylko pola pojazdu – danych posiadacza i właściciela (nazwisko, PESEL, adres)
nie zwracamy ani nie zapisujemy; zdjęcie też nie jest zapisywane.
"""

import base64
import binascii
import io
import re

from truckmaps.core.i18n import t

MAX_OUTPUT = 64 * 1024
"""Górna granica rozpakowanego tekstu – kod Aztec dowodu ma kilka kB."""


class RegistrationError(ValueError):
    """Nie udało się odczytać dowodu (komunikat w języku użytkownika)."""


def nrv2e_decompress(src: bytes, out_len: int) -> bytes:
    """Rozpakowanie NRV2E (wariant 8-bitowy UCL) – do znacznika końca albo [out_len] bajtów."""
    dst = bytearray()
    pos = 0
    bb = 0
    last_m_off = 1

    def byte() -> int:
        nonlocal pos
        if pos >= len(src):
            raise RegistrationError(t("registration.unreadable"))
        value = src[pos]
        pos += 1
        return value

    def bit() -> int:
        nonlocal bb
        bb = bb * 2 if bb & 0x7F else byte() * 2 + 1
        return (bb >> 8) & 1

    while len(dst) < out_len:
        while bit():
            dst.append(byte())
            if len(dst) >= out_len:
                return bytes(dst)
        m_off = 1
        while True:
            m_off = m_off * 2 + bit()
            if bit():
                break
            m_off = (m_off - 1) * 2 + bit()
            if m_off > 0x1000002:
                raise RegistrationError(t("registration.unreadable"))
        if m_off == 2:
            m_off = last_m_off
            m_len = bit()
        else:
            m_off = ((m_off - 3) * 256 + byte()) & 0xFFFFFFFF
            if m_off == 0xFFFFFFFF:
                break
            m_len = (m_off ^ 0xFFFFFFFF) & 1
            m_off >>= 1
            m_off += 1
            last_m_off = m_off
        if m_len:
            m_len = 1 + bit()
        elif bit():
            m_len = 3 + bit()
        else:
            m_len += 1
            while True:
                m_len = m_len * 2 + bit()
                if bit():
                    break
            m_len += 3
        m_len += m_off > 0x500
        start = len(dst) - m_off
        if start < 0:
            raise RegistrationError(t("registration.unreadable"))
        for i in range(m_len + 1):
            dst.append(dst[start + i])
    return bytes(dst[:out_len])


def decode_text(code: str) -> list[str]:
    """Pola dowodu z tekstu kodu Aztec (Base64)."""
    try:
        raw = base64.b64decode(code.strip() + "==", validate=False)
    except (binascii.Error, ValueError) as error:
        raise RegistrationError(t("registration.unreadable")) from error
    if len(raw) < 8:
        raise RegistrationError(t("registration.unreadable"))
    out_len = int.from_bytes(raw[:4], "little")
    if not 0 < out_len <= MAX_OUTPUT:
        raise RegistrationError(t("registration.unreadable"))
    text = nrv2e_decompress(raw[4:], out_len).decode("utf-16-le", errors="replace")
    fields = [f.strip() for f in text.replace("\r\n", "|").replace("\n", "|").split("|")]
    if len(fields) < 30:
        raise RegistrationError(t("registration.unreadable"))
    return fields


def read_image(data: bytes) -> str:
    """Tekst kodu Aztec ze zdjęcia dowodu (zxing-cpp)."""
    import zxingcpp
    from PIL import Image, UnidentifiedImageError

    try:
        image = Image.open(io.BytesIO(data))
        image.load()
    except (UnidentifiedImageError, OSError) as error:
        raise RegistrationError(t("registration.not_image")) from error
    image.thumbnail((3000, 3000))
    for barcode in zxingcpp.read_barcodes(image.convert("L"), formats=zxingcpp.BarcodeFormat.Aztec):
        if barcode.text:
            return barcode.text
    raise RegistrationError(t("registration.no_code"))


# Numery pól: nowy format (pierwsze pole zaczyna się od „XX”) i stary.
NEW = {"A": 7, "D1": 8, "D3": 12, "E": 13, "F1": 38, "F2": 39, "G": 41, "J": 42, "L": 44,
       "S1": 52, "S2": 53, "kind": 54, "year": 56, "axle": 58}  # fmt: skip
OLD = {"A": 5, "D1": 6, "D3": 10, "E": 11, "F1": 22, "F2": 23, "G": 25, "L": 28,
       "S1": 37, "S2": 38, "kind": 39, "year": 41, "axle": 43}  # fmt: skip


def _number(value: str | None) -> float | None:
    """Liczba z pola („18000”, „8100 kg”, „2,5”); brak liczby – ``None``."""
    match = re.search(r"\d+(?:[.,]\d+)?", (value or "").replace(" ", ""))
    return float(match.group(0).replace(",", ".")) if match else None


def _kind(text: str, category: str, gvw_kg: float | None) -> str | None:
    """Rodzaj pojazdu TruckMaps z „rodzaju pojazdu” z dowodu, a bez niego – z kategorii (J)."""
    text = text.upper()
    if "SIOD" in text and "CI" in text:
        return "tractor"
    if "NACZEPA" in text:
        return "semitrailer"
    if "PRZYCZEPA" in text:
        return "trailer"
    if "AUTOBUS" in text:
        return "bus"
    if "CIĘŻAR" in text or "CIEZAR" in text or "SPECJALNY" in text:
        return "rigid" if (gvw_kg or 0) > 3500 else "van"
    category = category.upper()
    if category.startswith("N1"):
        return "van"
    if category.startswith(("N2", "N3")):
        return "rigid"
    if category.startswith(("M2", "M3")):
        return "bus"
    if category.startswith(("O3", "O4")):
        return "trailer"
    return None


def vehicle_data(fields: list[str], index: dict[str, int] | None = None) -> dict:
    """Pola profilu pojazdu z pól dowodu – tylko te, które dowód zawiera (bez wymiarów)."""
    index = index or (NEW if fields[0].startswith("XX") else OLD)

    def get(key: str) -> str:
        i = index.get(key)
        return fields[i] if i is not None and i < len(fields) else ""

    gvw = _number(get("F2")) or _number(get("F1"))
    tare = _number(get("G"))
    axles = _number(get("L"))
    seats = _number(get("S1"))
    standing = _number(get("S2"))
    axle_kn = _number(get("axle"))
    year = _number(get("year"))
    vin = get("E").replace(" ", "").upper()
    data = {
        "name": " ".join(p for p in (get("D1"), get("D3")) if p and p != "-")[:100],
        "plate": get("A").replace(" ", "").upper()[:15] or None,
        "vin": vin[:17] or None,
        "kind": _kind(get("kind"), get("J"), gvw),
        "gvw_t": round(gvw / 1000, 2) if gvw else None,
        "tare_t": round(tare / 1000, 2) if tare else None,
        "axle_count": int(axles) if axles else None,
        # Nacisk osi w dowodzie jest w kN.
        "axle_load_t": round(axle_kn / 9.81, 1) if axle_kn else None,
        # S.1 obejmuje miejsce kierowcy; w profilu – miejsca bez kierowcy.
        "seats": int(seats) - 1 if seats and seats > 1 else None,
        "standing_places": int(standing) if standing else None,
        "production_year": int(year) if year and 1950 <= year <= 2100 else None,
    }
    return {key: value for key, value in data.items() if value not in (None, "")}


# Dowody z krajów UE (dyrektywa 1999/37/WE) mają te same kody pól – tekst ze zdjęcia
# (rozpoznany na telefonie) czytamy po kodach na początku linii: „E WMA06…”, „F.2: 18000”.
EU_CODES = {
    "A": "A",
    "D.1": "D1",
    "D.3": "D3",
    "E": "E",
    "F.1": "F1",
    "F.2": "F2",
    "G": "G",
    "J": "J",
    "L": "L",
    "S.1": "S1",
    "S.2": "S2",
}
_CODE_LINE = re.compile(
    r"^\s*\(?(A|D\s*\.?\s*[13]|E|F\s*\.?\s*[12]|G|J|L|S\s*\.?\s*[12])\s*[.):]?\s+(.+)$"
)
_VIN = re.compile(r"\b[A-HJ-NPR-Z0-9]{17}\b")


def text_fields(text: str) -> dict[str, str]:
    """Pola dowodu z rozpoznanego tekstu (kod → wartość); pierwsze wystąpienie kodu wygrywa."""
    found: dict[str, str] = {}
    for line in text.splitlines():
        match = _CODE_LINE.match(line.upper())
        if not match:
            continue
        code = re.sub(r"\s+", "", match.group(1))
        if len(code) == 2:  # „D1” bez kropki
            code = f"{code[0]}.{code[1]}"
        key = EU_CODES.get(code)
        if key and key not in found:
            found[key] = match.group(2).strip()
    if "E" not in found and (vin := _VIN.search(text.upper().replace(" ", ""))):
        found["E"] = vin.group(0)
    return found


def vehicle_data_from_text(text: str) -> dict:
    """Pola profilu z tekstu dowodu dowolnego kraju UE (bez rodzaju z „rodzaju pojazdu”)."""
    fields = text_fields(text)
    if len(fields) < 2:
        raise RegistrationError(t("registration.text_unreadable"))
    order = ["A", "D1", "D3", "E", "F1", "F2", "G", "J", "L", "S1", "S2"]
    values = [""] * 60
    index = {key: i for i, key in enumerate(order, start=1)}
    for key, value in fields.items():
        values[index[key]] = (
            re.sub(r"(?<=\d)[\s.](?=\d{3}\b)", "", value) if key[0] in "FGLS" else value
        )
    return vehicle_data(values, {**index, "kind": 0})
