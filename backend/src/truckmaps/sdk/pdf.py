"""Mały zapis PDF bez zależności: tekst, linie i prostokąty na stronach A4.

Czcionki standardowe PDF (Helvetica, Helvetica-Bold) z kodowaniem Windows-1250 opisanym
tablicą ``/Differences`` – polskie i środkowoeuropejskie znaki bez dołączania plików czcionek
(przeglądarki PDF mają te glify w czcionkach standardowych). Znaki spoza Windows-1250
zastępuje „?”. Szerokości liter z metryk Helvetica – do łamania wierszy.
"""

import unicodedata
import zlib
from dataclasses import dataclass

A4 = (595.0, 842.0)

# Metryki Helvetica (AFM, 1/1000 em) dla znaków 32–126.
_WIDTHS = [
    278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
    1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
    333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
    556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584,
]  # fmt: skip
_BOLD = 1.06
"""Helvetica-Bold jest średnio o tyle szersza."""

_MARKS = {
    "ACUTE": "acute", "GRAVE": "grave", "CIRCUMFLEX": "circumflex", "DIAERESIS": "dieresis",
    "CARON": "caron", "OGONEK": "ogonek", "DOT ABOVE": "dotaccent", "RING ABOVE": "ring",
    "CEDILLA": "cedilla", "DOUBLE ACUTE": "hungarumlaut", "BREVE": "breve", "TILDE": "tilde",
}  # fmt: skip
_SIGNS = {
    "€": "Euro", "‚": "quotesinglbase", "„": "quotedblbase", "…": "ellipsis", "†": "dagger",
    "‡": "daggerdbl", "‰": "perthousand", "‹": "guilsinglleft", "›": "guilsinglright",
    "‘": "quoteleft", "’": "quoteright", "“": "quotedblleft", "”": "quotedblright",
    "•": "bullet", "–": "endash", "—": "emdash", "™": "trademark", "¤": "currency",
    "¦": "brokenbar", "§": "section", "¨": "dieresis", "©": "copyright", "«": "guillemotleft",
    "¬": "logicalnot", "®": "registered", "°": "degree", "±": "plusminus", "´": "acute",
    "µ": "mu", "¶": "paragraph", "·": "periodcentered", "¸": "cedilla", "»": "guillemotright",
    "×": "multiply", "÷": "divide", "ˇ": "caron", "˘": "breve", "˛": "ogonek", "˙": "dotaccent",
    "˝": "hungarumlaut", "ß": "germandbls", "ł": "lslash", "Ł": "Lslash", "đ": "dcroat",
    "Đ": "Dcroat",
}  # fmt: skip
_REPLACE = {" ": " ", "­": "-", "‑": "-", "−": "-", "\t": " "}


def _glyph(ch: str) -> str | None:
    """Nazwa glifu (Adobe Glyph List) dla znaku Windows-1250 z kodem ≥ 128."""
    if ch in _SIGNS:
        return _SIGNS[ch]
    try:
        name = unicodedata.name(ch)
    except ValueError:
        return None
    for case in ("SMALL", "CAPITAL"):
        prefix = f"LATIN {case} LETTER "
        if name.startswith(prefix) and " WITH " in name:
            base, mark = name.removeprefix(prefix).split(" WITH ", 1)
            if len(base) == 1 and mark in _MARKS:
                letter = base.lower() if case == "SMALL" else base
                return letter + _MARKS[mark]
    return None


def _differences() -> tuple[dict[str, int], str]:
    codes: dict[str, int] = {}
    parts: list[str] = []
    for code in range(128, 256):
        ch = bytes([code]).decode("cp1250", errors="ignore")
        name = _glyph(ch) if ch else None
        if name:
            codes[ch] = code
            parts.append(f"{code} /{name}")
    return codes, " ".join(parts)


_CODES, _DIFFERENCES = _differences()


def encode(text: str) -> bytes:
    """Tekst w kodowaniu czcionki (ASCII + znaki z tablicy ``/Differences``)."""
    out = bytearray()
    for ch in text:
        ch = _REPLACE.get(ch, ch)
        if 32 <= ord(ch) < 127:
            out += ch.encode("ascii")
        elif ch in _CODES:
            out.append(_CODES[ch])
        else:
            base = unicodedata.normalize("NFKD", ch)[:1]
            out += base.encode("ascii") if base and 32 <= ord(base) < 127 else b"?"
    return bytes(out)


def _char_width(ch: str) -> int:
    code = ord(ch)
    if 32 <= code < 127:
        return _WIDTHS[code - 32]
    if ch in "łŁ":
        return 222 if ch == "ł" else 556
    base = unicodedata.normalize("NFKD", ch)[:1]
    if base and 32 <= ord(base) < 127:
        return _WIDTHS[ord(base) - 32]
    return 556


def text_width(text: str, size: float, bold: bool = False) -> float:
    width = sum(_char_width(ch) for ch in text) * size / 1000
    return width * _BOLD if bold else width


def wrap(text: str, size: float, width: float, bold: bool = False) -> list[str]:
    """Łamie tekst na wiersze nie szersze niż ``width`` (zachowuje podziały wierszy)."""
    lines: list[str] = []
    for paragraph in text.split("\n"):
        line = ""
        for word in paragraph.split(" "):
            candidate = f"{line} {word}" if line else word
            if text_width(candidate, size, bold) <= width:
                line = candidate
                continue
            if line:
                lines.append(line)
            # Słowo dłuższe niż wiersz – tniemy po znakach.
            while text_width(word, size, bold) > width and len(word) > 1:
                cut = len(word)
                while cut > 1 and text_width(word[:cut], size, bold) > width:
                    cut -= 1
                lines.append(word[:cut])
                word = word[cut:]
            line = word
        lines.append(line)
    return lines


def _escape(data: bytes) -> bytes:
    return data.replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)")


@dataclass(frozen=True)
class Image:
    """Obraz JPEG (RGB) do wstawienia w PDF bez dekodowania (``/DCTDecode``)."""

    data: bytes
    width: int
    height: int


class Pdf:
    """Strony A4; współrzędne od lewego górnego rogu (``y`` w dół), w punktach."""

    def __init__(self, title: str = "") -> None:
        self.title = title
        self.pages: list[list[bytes]] = []
        self.images: list[Image] = []
        self.add_page()

    @property
    def height(self) -> float:
        return A4[1]

    def add_page(self) -> None:
        self.pages.append([])

    def _op(self, op: str | bytes) -> None:
        self.pages[-1].append(op.encode("ascii") if isinstance(op, str) else op)

    def text(self, x: float, y: float, value: str, size: float = 9, bold: bool = False) -> None:
        """Tekst – ``y`` to linia bazowa."""
        font = "F2" if bold else "F1"
        body = _escape(encode(value))
        self._op(f"BT /{font} {size:g} Tf {x:.2f} {self.height - y:.2f} Td (".encode() + body)
        self._op(b") Tj ET")

    def line(self, x1: float, y1: float, x2: float, y2: float, width: float = 0.5) -> None:
        h = self.height
        self._op(f"{width:g} w {x1:.2f} {h - y1:.2f} m {x2:.2f} {h - y2:.2f} l S")

    def rect(self, x: float, y: float, w: float, h: float, width: float = 0.5) -> None:
        self._op(f"{width:g} w {x:.2f} {self.height - y - h:.2f} {w:.2f} {h:.2f} re S")

    def fill(self, x: float, y: float, w: float, h: float, gray: float = 0.92) -> None:
        self._op(f"q {gray:g} g {x:.2f} {self.height - y - h:.2f} {w:.2f} {h:.2f} re f Q")

    def fill_rgb(
        self, x: float, y: float, w: float, h: float, rgb: tuple[float, float, float]
    ) -> None:
        """Prostokąt wypełniony kolorem (składowe 0–1) z cienką ramką."""
        r, g, b = rgb
        self._op(
            f"q {r:g} {g:g} {b:g} rg 0.3 w {x:.2f} {self.height - y - h:.2f} {w:.2f} {h:.2f} re B Q"
        )

    def image(self, image: Image, x: float, y: float, w: float, h: float) -> None:
        if image not in self.images:
            self.images.append(image)
        name = f"Im{self.images.index(image) + 1}"
        self._op(f"q {w:.2f} 0 0 {h:.2f} {x:.2f} {self.height - y - h:.2f} cm /{name} Do Q")

    def output(self) -> bytes:
        objects: list[bytes] = []

        def add(body: bytes) -> int:
            objects.append(body)
            return len(objects)

        encoding = add(
            f"<< /Type /Encoding /BaseEncoding /WinAnsiEncoding "
            f"/Differences [{_DIFFERENCES}] >>".encode()
        )
        fonts = [
            add(
                f"<< /Type /Font /Subtype /Type1 /BaseFont /{name} "
                f"/Encoding {encoding} 0 R >>".encode()
            )
            for name in ("Helvetica", "Helvetica-Bold")
        ]
        images = [
            add(
                f"<< /Type /XObject /Subtype /Image /Width {im.width} /Height {im.height} "
                f"/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode "
                f"/Length {len(im.data)} >>\nstream\n".encode()
                + im.data
                + b"\nendstream"
            )
            for im in self.images
        ]
        xobjects = " ".join(f"/Im{i + 1} {ref} 0 R" for i, ref in enumerate(images))
        pages_id = len(objects) + 1 + 2 * len(self.pages) + 1
        kids = []
        for ops in self.pages:
            stream = zlib.compress(b"\n".join(ops))
            content = add(
                f"<< /Length {len(stream)} /Filter /FlateDecode >>\nstream\n".encode()
                + stream
                + b"\nendstream"
            )
            kids.append(
                add(
                    f"<< /Type /Page /Parent {pages_id} 0 R /MediaBox [0 0 {A4[0]:g} {A4[1]:g}] "
                    f"/Resources << /Font << /F1 {fonts[0]} 0 R /F2 {fonts[1]} 0 R >> "
                    f"/XObject << {xobjects} >> >> "
                    f"/Contents {content} 0 R >>".encode()
                )
            )
        info = add(b"<< /Title (" + _escape(encode(self.title)) + b") /Producer (TruckMaps) >>")
        pages = add(
            f"<< /Type /Pages /Kids [{' '.join(f'{k} 0 R' for k in kids)}] "
            f"/Count {len(kids)} >>".encode()
        )
        assert pages == pages_id
        catalog = add(f"<< /Type /Catalog /Pages {pages_id} 0 R >>".encode())

        out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
        offsets = []
        for number, body in enumerate(objects, start=1):
            offsets.append(len(out))
            out += f"{number} 0 obj\n".encode() + body + b"\nendobj\n"
        xref = len(out)
        out += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
        for offset in offsets:
            out += f"{offset:010d} 00000 n \n".encode()
        out += (
            f"trailer\n<< /Size {len(objects) + 1} /Root {catalog} 0 R /Info {info} 0 R >>\n"
            f"startxref\n{xref}\n%%EOF\n"
        ).encode()
        return bytes(out)
