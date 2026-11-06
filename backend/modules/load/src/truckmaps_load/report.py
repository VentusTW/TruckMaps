"""Plan załadunku w PDF: rzut z góry, naciski, bilans sił EN 12195-1, lista sprzętu VDI 2700."""

from datetime import date

from truckmaps.sdk.fleet import VehicleInfo
from truckmaps.sdk.i18n import t
from truckmaps.sdk.pdf import A4, Pdf, wrap

MARGIN = 40.0
WIDTH = A4[0] - 2 * MARGIN
# Grupy ładunku wg masy sztuki (jak w aplikacji): ciężkie, średnie, lekkie, luzem (inny wymiar).
HEAVY_KG, MEDIUM_KG = 900, 500
COLORS = {
    "heavy": (0.15, 0.35, 0.85),
    "medium": (0.15, 0.65, 0.35),
    "light": (0.45, 0.75, 0.95),
    "bulk": (0.95, 0.65, 0.15),
}


def group(piece, items) -> str:
    """Grupa sztuki na planie: ``heavy``, ``medium``, ``light`` albo ``bulk``."""
    if items[piece.item].kind == "custom":
        return "bulk"
    each = piece.weight_kg / max(1, piece.pieces)
    return "heavy" if each >= HEAVY_KG else "medium" if each >= MEDIUM_KG else "light"


def _n(value: float, digits: int = 1) -> str:
    text = f"{value:,.{digits}f}".replace(",", " ")
    return text.replace(".", ",") if t("load.pdf.decimal") == "," else text


class _Page:
    def __init__(self, title: str) -> None:
        self.pdf = Pdf(title)
        self.y = MARGIN

    def need(self, height: float) -> None:
        if self.y + height > A4[1] - MARGIN:
            self.pdf.add_page()
            self.y = MARGIN

    def heading(self, text: str) -> None:
        self.need(30)
        self.y += 16
        self.pdf.text(MARGIN, self.y, text, 11, bold=True)
        self.pdf.line(MARGIN, self.y + 4, MARGIN + WIDTH, self.y + 4, 0.4)
        self.y += 14

    def row(self, label: str, value: str, bold: bool = False) -> None:
        self.need(14)
        self.pdf.text(MARGIN, self.y, label, 9)
        self.pdf.text(MARGIN + WIDTH * 0.62, self.y, value, 9, bold=bold)
        self.y += 13

    def paragraph(self, text: str, size: float = 8) -> None:
        for line in wrap(text, size, WIDTH):
            self.need(size + 3)
            self.pdf.text(MARGIN, self.y, line, size)
            self.y += size + 2.5


def _deck(page: _Page, out, items) -> None:
    """Rzut z góry: palety w kolorach grup, pasy, środek ciężkości."""
    scale = WIDTH / out.deck_length_m
    height = out.deck_width_m * scale
    page.need(height + 30)
    x0, y0 = MARGIN, page.y
    pdf = page.pdf
    pdf.rect(x0, y0, WIDTH, height, 1)
    for p in out.placed:
        pdf.fill_rgb(
            x0 + p.x_m * scale, y0 + p.y_m * scale, p.length_m * scale, p.width_m * scale,
            COLORS[group(p, items)],
        )  # fmt: skip
        if p.pieces > 1:
            pdf.text(x0 + p.x_m * scale + 2, y0 + p.y_m * scale + 9, f"{p.pieces}L", 6)
    for r in out.rows:
        for k in range(r.straps):
            x = x0 + (r.x_m + r.length_m * (k + 1) / (r.straps + 1)) * scale
            pdf.line(x, y0 - 2, x, y0 + height + 2, 0.8)
    if out.cog_m is not None:
        cx, cy = x0 + out.cog_m * scale, y0 + height / 2
        pdf.rect(cx - 3, cy - 3, 6, 6, 1.2)
        pdf.text(cx + 5, cy - 4, t("load.pdf.cog", value=_n(out.cog_m, 2)), 7, bold=True)
    pdf.text(x0, y0 + height + 12, t("load.pdf.front"), 7)
    legend = x0 + WIDTH * 0.35
    for name, rgb in COLORS.items():
        pdf.fill_rgb(legend, y0 + height + 5, 8, 8, rgb)
        pdf.text(legend + 11, y0 + height + 12, t(f"load.group.{name}"), 7)
        legend += WIDTH * 0.16
    page.y = y0 + height + 22


def to_pdf(out, items, vehicle: VehicleInfo, checked: set[str], approved: bool) -> bytes:
    title = t("load.pdf.title")
    page = _Page(f"{title} {out.reference}".strip())
    pdf = page.pdf
    pdf.text(MARGIN, page.y + 14, title, 15, bold=True)
    head = [vehicle.name, vehicle.plate or "", date.today().isoformat()]
    if out.reference:
        head.insert(0, t("load.pdf.reference", value=out.reference))
    pdf.text(MARGIN, page.y + 30, " · ".join(h for h in head if h), 9)
    status = t("load.pdf.approved") if approved else t("load.pdf.draft")
    pdf.text(MARGIN + WIDTH * 0.72, page.y + 14, status, 9, bold=True)
    page.y += 44

    page.heading(t("load.pdf.summary"))
    page.row(t("load.pdf.places"), f"{out.places_used} / {out.pallet_places}")
    page.row(
        t("load.pdf.ldm"),
        f"{_n(out.ldm, 2)} LDM · {_n(out.used_length_m, 2)} / {_n(out.deck_length_m, 2)} m",
    )
    payload = f" / {_n(out.payload_kg / 1000, 2)} t" if out.payload_kg else ""
    page.row(t("load.pdf.weight"), f"{_n(out.weight_kg / 1000, 2)} t{payload}")
    page.row(t("load.pdf.body"), t(f"load.body.{out.body_code}"))
    page.row(t("load.pdf.fits"), t("load.pdf.yes") if out.fits else t("load.pdf.no"), bold=True)
    page.y += 4
    _deck(page, out, items)

    if out.axles or out.tractor:
        page.heading(t("load.pdf.axles"))
        if out.tractor:
            tr = out.tractor
            page.row(
                t("load.pdf.tractor_front"),
                f"{_n(tr.front_kg / 1000)} / {_n(tr.front_limit_kg / 1000)} t",
            )
            page.row(
                t("load.pdf.tractor_drive"),
                f"{_n(tr.drive_kg / 1000)} / {_n(tr.drive_limit_kg / 1000)} t",
            )
        for a in out.axles:
            limit = f" / {_n(a.limit_kg / 1000)} t" if a.limit_kg else ""
            page.row(t(f"load.axle_{a.name}"), f"{_n(a.load_kg / 1000)} t{limit}", bold=a.over)
        if out.tractor:
            tr = out.tractor
            page.row(
                t("load.pdf.gvw"),
                f"{_n(tr.gvw_kg / 1000, 2)} / {_n(tr.gvw_limit_kg / 1000, 2)} t",
                bold=True,
            )
            page.row(t("load.pdf.drive_share"), f"{_n(tr.drive_share * 100)} % (min. 25 %)")

    if out.forces:
        f = out.forces
        page.heading(t("load.pdf.forces"))
        page.row(t("load.pdf.mu"), _n(f.mu, 2))
        page.row(t("load.pdf.forward"), f"{_n(f.forward_kN)} kN")
        page.row(t("load.pdf.side"), f"{_n(f.side_kN)} kN")
        page.row(t("load.pdf.friction"), f"{_n(f.friction_kN)} kN")
        page.row(t("load.pdf.rest"), f"{_n(f.rest_forward_kN)} kN")
        if f.wall_kN is not None:
            page.row(t("load.pdf.wall"), f"{_n(f.wall_kN)} kN")
        page.row(
            t("load.pdf.tension"),
            f"{_n(f.tension_daN, 0)} daN ({f.straps} × {f.strap_daN} daN)",
            bold=True,
        )

    page.heading(t("load.pdf.equipment"))
    for e in out.equipment:
        mark = "[X]" if e.id in checked else "[  ]"
        page.row(f"{mark}  {t(f'load.gear.{e.id}')}", t("load.pdf.pieces", count=e.required))

    page.heading(t("load.pdf.norms"))
    for n in out.norms:
        page.row(
            t(f"load.norm.{n.id}"), t("load.pdf.ok") if n.ok else t("load.pdf.check"), bold=not n.ok
        )

    if out.warnings:
        page.heading(t("load.pdf.warnings"))
        for w in out.warnings:
            page.paragraph(f"• {w}", 8.5)

    page.heading(t("load.pdf.disclaimer_title"))
    page.paragraph(t("load.pdf.disclaimer"))
    page.need(60)
    page.y += 40
    for i, who in enumerate(("load.pdf.loader", "load.pdf.driver")):
        x = MARGIN + i * WIDTH / 2
        pdf.line(x, page.y, x + WIDTH / 2 - 30, page.y, 0.4)
        pdf.text(x, page.y + 11, t(who), 8)
    return pdf.output()
