"""Wydruk dokumentu: PDF (``pdf.Pdf``) i strona HTML do druku z przeglądarki."""

import base64
import html
from dataclasses import dataclass

from truckmaps.sdk.i18n import language, t
from truckmaps_documents.catalog import Field, Kind
from truckmaps_documents.pdf import Image, Pdf, wrap

MARGIN = 36.0
LABEL = 6.5
VALUE = 9.0
LEAD = 11.0
PAD = 4.0


@dataclass
class Doc:
    kind: Kind
    number: str
    data: dict
    fields: list[Field] | None = None
    """Pola wg szablonu firmy; ``None`` – wszystkie pola wzoru."""
    terms: str = ""
    """Klauzule z szablonu firmy (gdy rodzaj nie ma własnego pola „terms”)."""
    logo: Image | None = None

    def __post_init__(self) -> None:
        if self.fields is None:
            self.fields = list(self.kind.fields)


def label(f: Field) -> str:
    text = f.label or t(f"documents.field.{f.key}")
    return f"{f.box}. {text}" if f.box else text


def value_text(value: object) -> str:
    if value is None:
        return ""
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value)


def _rows(fields: list[Field]) -> list[list[Field]]:
    """Pola w wierszach wydruku wg szerokości (suma ≤ 1)."""
    rows: list[list[Field]] = []
    used = 1.0
    for f in fields:
        if f.type == "rows" or used + f.width > 1.0001:
            rows.append([])
            used = 0.0
        rows[-1].append(f)
        used += 1.0 if f.type == "rows" else f.width
    return rows


class _Writer:
    def __init__(self, title: str) -> None:
        self.pdf = Pdf(title)
        self.width = 595.0 - 2 * MARGIN
        self.y = MARGIN

    def room(self, height: float) -> None:
        if self.y + height > self.pdf.height - MARGIN:
            self.pdf.add_page()
            self.y = MARGIN

    def boxes(self, row: list[Field], data: dict) -> None:
        cells = []
        for f in row:
            w = self.width * f.width
            lines = wrap(value_text(data.get(f.key)), VALUE, w - 2 * PAD)
            title = wrap(label(f), LABEL, w - 2 * PAD)
            cells.append((f, w, title, lines))
        height = max(
            PAD * 2 + len(title) * (LABEL + 1.5) + max(1, len(lines)) * LEAD
            for _, _, title, lines in cells
        )
        self.room(height)
        x = MARGIN
        for _, w, title, lines in cells:
            self.pdf.rect(x, self.y, w, height)
            y = self.y + PAD + LABEL
            for line in title:
                self.pdf.text(x + PAD, y, line, LABEL)
                y += LABEL + 1.5
            y += VALUE - LABEL + 1
            for line in lines:
                self.pdf.text(x + PAD, y, line, VALUE)
                y += LEAD
            x += w
        self.y += height

    def table(self, f: Field, rows: list[dict]) -> None:
        col = self.width / len(f.columns)
        title_lines = wrap(label(f), LABEL, self.width - 2 * PAD)
        heads = [wrap(t(f"documents.col.{c}"), LABEL, col - 2 * PAD) for c in f.columns]
        head_h = PAD * 2 + max(len(h) for h in heads) * (LABEL + 1.5)
        top = PAD + len(title_lines) * (LABEL + 1.5)
        self.room(top + head_h + LEAD + PAD)
        self.pdf.text(MARGIN + PAD, self.y + PAD + LABEL, title_lines[0], LABEL, bold=True)
        self.y += top
        self.pdf.fill(MARGIN, self.y, self.width, head_h)
        for i, head in enumerate(heads):
            y = self.y + PAD + LABEL
            for line in head:
                self.pdf.text(MARGIN + i * col + PAD, y, line, LABEL, bold=True)
                y += LABEL + 1.5
        self.pdf.rect(MARGIN, self.y, self.width, head_h)
        self.y += head_h
        for row in rows or [{}]:
            cells = [wrap(value_text(row.get(c)), VALUE, col - 2 * PAD) for c in f.columns]
            height = PAD * 2 + max(len(c) for c in cells) * LEAD
            self.room(height)
            for i, lines in enumerate(cells):
                y = self.y + PAD + VALUE
                for line in lines:
                    self.pdf.text(MARGIN + i * col + PAD, y, line, VALUE)
                    y += LEAD
                self.pdf.rect(MARGIN + i * col, self.y, col, height)
            self.y += height
        self.y += PAD

    def paragraph(self, title: str, text: str) -> None:
        lines = wrap(text, VALUE - 1, self.width)
        self.room(LABEL + 2 * LEAD)
        self.y += PAD
        self.pdf.text(MARGIN, self.y + LABEL, title, LABEL + 1, bold=True)
        self.y += LABEL + PAD + 2
        for line in lines:
            self.room(LEAD)
            self.y += LEAD - 1
            self.pdf.text(MARGIN, self.y, line, VALUE - 1)

    def signatures(self, keys: tuple[str, ...]) -> None:
        if not keys:
            return
        height = 60.0
        self.room(height + PAD * 3)
        self.y += PAD * 3
        w = self.width / len(keys)
        for i, key in enumerate(keys):
            x = MARGIN + i * w
            self.pdf.rect(x, self.y, w, height)
            for j, line in enumerate(wrap(t(f"documents.sign.{key}"), LABEL, w - 2 * PAD)):
                self.pdf.text(x + PAD, self.y + PAD + LABEL + j * (LABEL + 1.5), line, LABEL)
        self.y += height


def to_pdf(doc: Doc) -> bytes:
    title = t(f"documents.kind.{doc.kind.id}")
    writer = _Writer(f"{title} {doc.number}")
    pdf = writer.pdf
    if doc.logo:
        # Logo w prawym górnym rogu, najwyżej 160 × 40 pt.
        scale = min(160 / doc.logo.width, 40 / doc.logo.height)
        w, h = doc.logo.width * scale, doc.logo.height * scale
        pdf.image(doc.logo, 595 - MARGIN - w, MARGIN - 6, w, h)
    pdf.text(MARGIN, MARGIN + 14, title, 14, bold=True)
    pdf.text(MARGIN, MARGIN + 28, t("documents.text.number", value=doc.number), VALUE)
    basis = wrap(t(f"documents.basis.{doc.kind.id}"), LABEL, writer.width)
    for i, line in enumerate(basis):
        pdf.text(MARGIN, MARGIN + 40 + i * (LABEL + 1.5), line, LABEL)
    writer.y = MARGIN + 44 + len(basis) * (LABEL + 1.5)
    for row in _rows(doc.fields):
        if row[0].type == "rows":
            writer.table(row[0], doc.data.get(row[0].key) or [])
        else:
            writer.boxes(row, doc.data)
    if doc.terms and doc.kind.get("terms") is None:
        writer.paragraph(t("documents.field.terms"), doc.terms)
    writer.signatures(doc.kind.signatures)
    return pdf.output()


def to_html(doc: Doc) -> str:
    e = html.escape
    title = t(f"documents.kind.{doc.kind.id}")
    parts: list[str] = []
    for row in _rows(doc.fields):
        if row[0].type == "rows":
            f = row[0]
            head = "".join(f"<th>{e(t(f'documents.col.{c}'))}</th>" for c in f.columns)
            body = "".join(
                "<tr>" + "".join(f"<td>{e(value_text(r.get(c)))}</td>" for c in f.columns) + "</tr>"
                for r in (doc.data.get(f.key) or [{}])
            )
            parts.append(
                f'<div class="cell full"><div class="l">{e(label(f))}</div>'
                f"<table><tr>{head}</tr>{body}</table></div>"
            )
            continue
        for f in row:
            value = e(value_text(doc.data.get(f.key)))
            parts.append(
                f'<div class="cell" style="width:{f.width * 100:.2f}%">'
                f'<div class="l">{e(label(f))}</div><div class="v">{value}</div></div>'
            )
    terms = ""
    if doc.terms and doc.kind.get("terms") is None:
        terms = f'<h3>{e(t("documents.field.terms"))}</h3><p class="v">{e(doc.terms)}</p>'
    signs = "".join(
        f'<div class="sign"><div class="l">{e(t(f"documents.sign.{k}"))}</div></div>'
        for k in doc.kind.signatures
    )
    logo = ""
    if doc.logo:
        data = base64.b64encode(doc.logo.data).decode()
        logo = f'<img class="logo" src="data:image/jpeg;base64,{data}" alt="">'
    return f"""<!doctype html><html lang="{language()}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{e(title)} {e(doc.number)}</title>
<style>
body{{font-family:Arial,Helvetica,sans-serif;margin:16px;font-size:13px}}
.logo{{float:right;max-width:220px;max-height:56px}}
h1{{font-size:20px;margin:0}} .basis{{font-size:10px;color:#555;margin:4px 0 10px}}
.grid{{display:flex;flex-wrap:wrap;border-left:1px solid #000;border-top:1px solid #000}}
.cell{{box-sizing:border-box;border-right:1px solid #000;border-bottom:1px solid #000;
padding:4px;min-height:44px}} .full{{width:100%}}
.l{{font-size:9px;color:#333}} .v{{white-space:pre-wrap}}
table{{width:100%;border-collapse:collapse;margin-top:2px}}
th,td{{border:1px solid #000;padding:2px 4px;text-align:left;vertical-align:top}}
th{{background:#eee;font-size:10px}}
.signs{{display:flex;margin-top:16px}} .sign{{flex:1;border:1px solid #000;height:70px;padding:4px}}
@media print{{body{{margin:0}}}}
</style></head><body>
{logo}<h1>{e(title)}</h1><div>{e(t("documents.text.number", value=doc.number))}</div>
<div class="basis">{e(t(f"documents.basis.{doc.kind.id}"))}</div>
<div class="grid">{"".join(parts)}</div>{terms}
<div class="signs">{signs}</div>
</body></html>"""
