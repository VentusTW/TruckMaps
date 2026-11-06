"""Dokumenty transportowe: szablony firmy, autouzupełnianie z danych systemu, PDF i HTML.

Pierwsze rodzaje: list przewozowy CMR, zlecenie transportowe, karta drogowa (katalog
dokumentów i mapowanie pól – ``docs/dokumenty-transportowe.md``). Dane firmy, których nie
ma w rdzeniu (adres, licencja, polisa OCP…), są w profilu dokumentów firmy. Trasę z planera
i wynik Planu załadunku przekazuje aplikacja – moduł nie zależy od innych modułów.
Dokumenty widzą członkowie firmy; profil i szablony zmieniają właściciel i dyspozytorzy,
dokument poprawia lub usuwa jego autor albo obsługa firmy. Korzysta tylko z SDK rdzenia.
"""

import base64
import binascii
import io
import json
import re
import unicodedata
import uuid
from datetime import UTC, date, datetime, time
from importlib import resources
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Response, status
from PIL import Image as PilImage
from PIL import UnidentifiedImageError
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import JSON, DateTime, LargeBinary, String, UniqueConstraint, func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column

from truckmaps.sdk import (
    DASHBOARD_FEED,
    CoreContext,
    DashboardKpi,
    DashboardPart,
    Module,
    Principal,
    i18n,
)
from truckmaps.sdk.i18n import t
from truckmaps_documents import render
from truckmaps_documents.catalog import KINDS, Kind
from truckmaps_documents.catalog import Field as DocField
from truckmaps_documents.pdf import Image
from truckmaps_documents.prefill import (
    CargoIn,
    ExtraField,
    Profile,
    RouteIn,
    Sources,
    Template,
    fields_for,
    prefill,
)

MANAGERS = {"owner", "dispatcher"}
MAX_LIST = 200
MAX_LOGO_BYTES = 2 * 1024 * 1024
LOGO_BOX = (800, 300)
"""Logo zapisujemy jako JPEG najwyżej tej wielkości [px]."""


def _now() -> datetime:
    return datetime.now(UTC)


class Base(DeclarativeBase):
    pass


class DocumentProfile(Base):
    __tablename__ = "document_profiles"

    company_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    data: Mapped[dict] = mapped_column(JSON, default=dict)
    logo: Mapped[bytes | None] = mapped_column(LargeBinary)
    """Logo firmy (JPEG) do dokumentów."""
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class DocumentTemplate(Base):
    __tablename__ = "document_templates"
    __table_args__ = (UniqueConstraint("company_id", "kind"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    company_id: Mapped[str] = mapped_column(String(36), index=True)
    kind: Mapped[str] = mapped_column(String(30))
    data: Mapped[dict] = mapped_column(JSON, default=dict)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class Document(Base):
    __tablename__ = "documents"
    __table_args__ = (UniqueConstraint("company_id", "number"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    company_id: Mapped[str] = mapped_column(String(36), index=True)
    kind: Mapped[str] = mapped_column(String(30))
    number: Mapped[str] = mapped_column(String(40))
    vehicle_id: Mapped[str | None] = mapped_column(String(36), index=True)
    data: Mapped[dict] = mapped_column(JSON, default=dict)
    created_by: Mapped[str] = mapped_column(String(255))
    created_by_name: Mapped[str] = mapped_column(String(200), default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class FieldOut(BaseModel):
    key: str
    type: str
    label: str
    width: float
    box: str
    columns: list[dict[str, str]]


class KindOut(BaseModel):
    id: str
    name: str
    basis: str
    fields: list[FieldOut]


class TemplateOut(Template):
    kind: str
    fields: list[FieldOut]
    """Pola dokumentu wg szablonu (bez ukrytych, z polami firmy)."""


class ProfileOut(Profile):
    has_logo: bool = False
    logo: str | None = None
    """Logo (JPEG w base64) do podglądu w aplikacji."""


class LogoIn(BaseModel):
    image: str = Field(description="PNG albo JPEG w base64")


class PrefillIn(BaseModel):
    kind: str
    company_id: str
    vehicle_id: str | None = None
    driver_name: str = Field(default="", max_length=200)
    driver_phone: str = Field(default="", max_length=40)
    route: RouteIn | None = None
    cargo: CargoIn | None = None
    date_from: date | None = None
    date_to: date | None = None


class PrefillOut(BaseModel):
    data: dict[str, Any]
    sources: dict[str, str]
    warnings: list[str]


class DocumentIn(BaseModel):
    data: dict[str, Any] = Field(default_factory=dict)
    vehicle_id: str | None = None

    @field_validator("data")
    @classmethod
    def _small(cls, value: dict) -> dict:
        if len(json.dumps(value, default=str)) > 100_000:
            raise ValueError(t("documents.too_large"))
        return value


class NewDocumentIn(DocumentIn):
    kind: str
    company_id: str


class DocumentOut(BaseModel):
    id: str
    company_id: str
    kind: str
    number: str
    vehicle_id: str | None
    data: dict[str, Any]
    created_by_name: str
    created_at: datetime
    updated_at: datetime


def _out(doc: Document) -> DocumentOut:
    return DocumentOut(
        id=doc.id,
        company_id=doc.company_id,
        kind=doc.kind,
        number=doc.number,
        vehicle_id=doc.vehicle_id,
        data=doc.data or {},
        created_by_name=doc.created_by_name,
        created_at=doc.created_at,
        updated_at=doc.updated_at,
    )


def kind_or_404(kind: str) -> Kind:
    found = KINDS.get(kind)
    if found is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, t("documents.unknown_kind"))
    return found


def field_out(f: DocField) -> FieldOut:
    return FieldOut(
        key=f.key,
        type=f.type,
        label=render.label(f),
        width=f.width,
        box=f.box,
        columns=[{"key": c, "label": t(f"documents.col.{c}")} for c in f.columns],
    )


def all_fields(kind: Kind, template: Template) -> list[DocField]:
    """Pola wzoru i pola firmy – także ukryte (ukrycie nie kasuje wpisanych danych)."""
    return fields_for(kind, template.model_copy(update={"hidden": []}))


def _slug(text: str) -> str:
    ascii_text = unicodedata.normalize("NFKD", text.replace("ł", "l").replace("Ł", "L"))
    ascii_text = ascii_text.encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "_", ascii_text).strip("_")[:30] or "field"


def normalize_template(kind: Kind, data: Template) -> Template:
    """Klucze pól firmy (``x_…``, unikalne), tylko znane pola w etykietach, ukryciach
    i wartościach domyślnych."""
    extra: list[ExtraField] = []
    used = {f.key for f in kind.fields}
    for x in data.extra_fields:
        key = x.key if x.key.startswith("x_") else f"x_{_slug(x.key or x.label)}"
        base, n = key, 2
        while key in used:
            key, n = f"{base}_{n}", n + 1
        used.add(key)
        extra.append(x.model_copy(update={"key": key, "label": x.label.strip()}))
    texts = {f.key for f in kind.fields if f.type != "rows"} | {x.key for x in extra}
    return Template(
        defaults={k: str(v)[:5000] for k, v in data.defaults.items() if k in texts},
        hidden=[k for k in dict.fromkeys(data.hidden) if k in used],
        labels={
            k: v.strip()[:120]
            for k, v in data.labels.items()
            if kind.get(k) is not None and v.strip()
        },
        extra_fields=extra,
        terms=data.terms,
    )


def logo_jpeg(encoded: str) -> bytes:
    """Obraz z aplikacji → JPEG (białe tło pod przezroczystością, najwyżej ``LOGO_BOX``)."""
    try:
        raw = base64.b64decode(encoded, validate=True)
        if len(raw) > MAX_LOGO_BYTES:
            raise ValueError
        source = PilImage.open(io.BytesIO(raw))
        source.load()
    except (binascii.Error, ValueError, UnidentifiedImageError, OSError):
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_CONTENT, t("documents.bad_logo")
        ) from None
    rgba = source.convert("RGBA")
    image = PilImage.new("RGB", rgba.size, "white")
    image.paste(rgba, mask=rgba.getchannel("A"))
    image.thumbnail(LOGO_BOX)
    out = io.BytesIO()
    image.save(out, "JPEG", quality=88)
    return out.getvalue()


def clean(fields: list[DocField], data: dict) -> dict:
    """Tylko pola dokumentu; tabele – lista wierszy z kolumnami, reszta jako tekst."""
    out: dict[str, Any] = {}
    for f in fields:
        value = data.get(f.key)
        if value in (None, ""):
            continue
        if f.type == "rows":
            if not isinstance(value, list):
                continue
            out[f.key] = [
                {c: row[c] for c in f.columns if c in row and row[c] not in (None, "")}
                for row in value[:200]
                if isinstance(row, dict)
            ]
        elif isinstance(value, int | float) and not isinstance(value, bool):
            out[f.key] = value
        else:
            out[f.key] = str(value)[:5000]
    return out


def _filename(doc: Document) -> str:
    return "".join(c if c.isalnum() or c in "-_" else "_" for c in doc.number)


class DocumentsModule(Module):
    id = "documents"
    name = "Dokumenty"
    version = "0.1.0"
    requires_core = ">=0.1,<1.0"

    def register(self, ctx: CoreContext) -> None:
        for file in (resources.files("truckmaps_documents") / "locales").iterdir():
            if file.name.endswith(".json"):
                i18n.register(file.name.removesuffix(".json"), json.loads(file.read_text("utf-8")))

        router = APIRouter()
        User = Annotated[Principal, Depends(ctx.auth.current_user)]
        Db = Annotated[Session, Depends(ctx.storage.session)]
        fleet = ctx.fleet

        def member(db: Session, user: Principal, company_id: str) -> tuple[str, str]:
            """(rola, imię) członka firmy; obcy – 404."""
            for m in fleet.members(db, company_id):
                if m.subject == user.subject:
                    return m.role, m.name
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("documents.company_not_found"))

        def manager(db: Session, user: Principal, company_id: str) -> None:
            if member(db, user, company_id)[0] not in MANAGERS:
                raise HTTPException(status.HTTP_403_FORBIDDEN, t("documents.forbidden"))

        def profile_of(db: Session, company_id: str) -> Profile:
            found = db.get(DocumentProfile, company_id)
            return Profile.model_validate(found.data) if found else Profile()

        def template_of(db: Session, company_id: str, kind: str) -> Template:
            found = db.scalar(
                select(DocumentTemplate).where(
                    DocumentTemplate.company_id == company_id, DocumentTemplate.kind == kind
                )
            )
            return Template.model_validate(found.data) if found else Template()

        def check_vehicle(db: Session, user: Principal, vehicle_id: str, company_id: str) -> None:
            vehicle = fleet.vehicle(db, user, vehicle_id)
            if vehicle is None or vehicle.company_id not in (company_id, None):
                raise HTTPException(status.HTTP_404_NOT_FOUND, t("documents.vehicle_not_found"))

        def load(db: Session, user: Principal, doc_id: str) -> tuple[Document, str]:
            doc = db.get(Document, doc_id)
            if doc is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, t("documents.not_found"))
            try:
                role, _ = member(db, user, doc.company_id)
            except HTTPException:
                raise HTTPException(status.HTTP_404_NOT_FOUND, t("documents.not_found")) from None
            return doc, role

        def editable(doc: Document, role: str, user: Principal) -> None:
            if role not in MANAGERS and doc.created_by != user.subject:
                raise HTTPException(status.HTTP_403_FORBIDDEN, t("documents.forbidden"))

        def next_number(db: Session, kind: Kind, company_id: str) -> str:
            today = _now()
            prefix = f"{kind.prefix}/{today:%Y/%m}/"
            # Najwyższy numer w miesiącu + 1 (po usunięciu dokumentu numery się nie powtarzają).
            last = db.scalar(
                select(func.max(Document.number)).where(
                    Document.company_id == company_id, Document.number.like(f"{prefix}%")
                )
            )
            suffix = last.removeprefix(prefix) if last else "0"
            return f"{prefix}{(int(suffix) if suffix.isdigit() else 0) + 1:04d}"

        @router.get("/kinds")
        def kinds() -> list[KindOut]:
            """Rodzaje dokumentów z polami (etykiety w języku użytkownika)."""
            return [
                KindOut(
                    id=k.id,
                    name=t(f"documents.kind.{k.id}"),
                    basis=t(f"documents.basis.{k.id}"),
                    fields=[field_out(f) for f in k.fields],
                )
                for k in KINDS.values()
            ]

        def profile_row(db: Session, company_id: str) -> DocumentProfile:
            found = db.get(DocumentProfile, company_id)
            if found is None:
                found = DocumentProfile(company_id=company_id, data={})
                db.add(found)
            return found

        def profile_out(db: Session, company_id: str) -> ProfileOut:
            found = db.get(DocumentProfile, company_id)
            data = profile_of(db, company_id).model_dump()
            logo = base64.b64encode(found.logo).decode() if found and found.logo else None
            return ProfileOut(**data, has_logo=logo is not None, logo=logo)

        @router.get("/profile")
        def get_profile(company_id: str, user: User, db: Db) -> ProfileOut:
            member(db, user, company_id)
            return profile_out(db, company_id)

        @router.put("/profile")
        def put_profile(company_id: str, data: Profile, user: User, db: Db) -> ProfileOut:
            manager(db, user, company_id)
            found = profile_row(db, company_id)
            found.data = data.model_dump()
            found.updated_at = _now()
            db.commit()
            return profile_out(db, company_id)

        @router.put("/profile/logo")
        def put_logo(company_id: str, data: LogoIn, user: User, db: Db) -> ProfileOut:
            """Logo firmy (PNG albo JPEG) – zapisane jako JPEG, drukowane w nagłówku dokumentów."""
            manager(db, user, company_id)
            found = profile_row(db, company_id)
            found.logo = logo_jpeg(data.image)
            found.updated_at = _now()
            db.commit()
            return profile_out(db, company_id)

        @router.delete("/profile/logo")
        def delete_logo(company_id: str, user: User, db: Db) -> ProfileOut:
            manager(db, user, company_id)
            found = db.get(DocumentProfile, company_id)
            if found is not None:
                found.logo = None
                db.commit()
            return profile_out(db, company_id)

        @router.get("/profile/logo")
        def get_logo(company_id: str, user: User, db: Db) -> Response:
            member(db, user, company_id)
            found = db.get(DocumentProfile, company_id)
            if found is None or not found.logo:
                raise HTTPException(status.HTTP_404_NOT_FOUND, t("documents.no_logo"))
            return Response(found.logo, media_type="image/jpeg")

        def template_out(kind: Kind, template: Template) -> TemplateOut:
            return TemplateOut(
                kind=kind.id,
                fields=[field_out(f) for f in fields_for(kind, template)],
                **template.model_dump(),
            )

        @router.get("/templates/{kind}")
        def get_template(kind: str, company_id: str, user: User, db: Db) -> TemplateOut:
            """Szablon firmy i pola dokumentu wg niego (formularz w aplikacji)."""
            found_kind = kind_or_404(kind)
            member(db, user, company_id)
            return template_out(found_kind, template_of(db, company_id, kind))

        @router.put("/templates/{kind}")
        def put_template(
            kind: str, company_id: str, data: Template, user: User, db: Db
        ) -> TemplateOut:
            """Wartości domyślne, ukryte pola, zmienione etykiety, pola dodane przez firmę
            i warunki na końcu dokumentu."""
            found_kind = kind_or_404(kind)
            manager(db, user, company_id)
            data = normalize_template(found_kind, data)
            found = db.scalar(
                select(DocumentTemplate).where(
                    DocumentTemplate.company_id == company_id, DocumentTemplate.kind == kind
                )
            )
            if found is None:
                found = DocumentTemplate(company_id=company_id, kind=kind)
                db.add(found)
            found.data = data.model_dump()
            found.updated_at = _now()
            db.commit()
            return template_out(found_kind, data)

        @router.post("/prefill")
        def make_prefill(data: PrefillIn, user: User, db: Db) -> PrefillOut:
            """Podpowiedzi pól z danych firmy, pojazdu, trasy, ładunku i przejazdów."""
            kind_or_404(data.kind)
            member(db, user, data.company_id)
            src = Sources(
                company=fleet.company(db, data.company_id),
                profile=profile_of(db, data.company_id),
                template=template_of(db, data.company_id, data.kind),
                route=data.route,
                cargo=data.cargo,
                driver_name=data.driver_name,
                driver_phone=data.driver_phone,
                today=_now().date(),
            )
            if data.vehicle_id:
                check_vehicle(db, user, data.vehicle_id, data.company_id)
                src.vehicle = fleet.driving(db, data.vehicle_id)
                driver = src.vehicle.assigned_driver if src.vehicle else None
                if driver and not src.driver_name:
                    names = {m.subject: m.name for m in fleet.members(db, data.company_id)}
                    src.driver_name = names.get(driver, "")
                if data.kind == "road_card":
                    start = data.date_from or src.today
                    end = data.date_to or start
                    if end < start:
                        raise HTTPException(
                            status.HTTP_422_UNPROCESSABLE_CONTENT, t("documents.bad_period")
                        )
                    src.period = (start, end)
                    src.trips = fleet.trips(
                        db,
                        vehicle_ids=[data.vehicle_id],
                        since=datetime.combine(start, time.min, UTC),
                    )
            result = prefill(data.kind, src)
            return PrefillOut(data=result.data, sources=result.sources, warnings=result.warnings)

        @router.get("/documents")
        def list_documents(
            company_id: str,
            user: User,
            db: Db,
            kind: str | None = None,
            vehicle_id: str | None = None,
        ) -> list[DocumentOut]:
            member(db, user, company_id)
            query = select(Document).where(Document.company_id == company_id)
            if kind:
                query = query.where(Document.kind == kind)
            if vehicle_id:
                query = query.where(Document.vehicle_id == vehicle_id)
            query = query.order_by(Document.created_at.desc()).limit(MAX_LIST)
            return [_out(d) for d in db.scalars(query)]

        @router.post("/documents", status_code=status.HTTP_201_CREATED)
        def create_document(data: NewDocumentIn, user: User, db: Db) -> DocumentOut:
            kind = kind_or_404(data.kind)
            _, name = member(db, user, data.company_id)
            if data.vehicle_id:
                check_vehicle(db, user, data.vehicle_id, data.company_id)
            for _attempt in range(3):
                doc = Document(
                    company_id=data.company_id,
                    kind=kind.id,
                    number=next_number(db, kind, data.company_id),
                    vehicle_id=data.vehicle_id,
                    data=clean(
                        all_fields(kind, template_of(db, data.company_id, kind.id)), data.data
                    ),
                    created_by=user.subject,
                    created_by_name=name,
                )
                db.add(doc)
                try:
                    db.commit()
                except IntegrityError:
                    # Ten sam numer nadany równolegle – następny.
                    db.rollback()
                    continue
                return _out(doc)
            raise HTTPException(status.HTTP_409_CONFLICT, t("documents.number_taken"))

        @router.get("/documents/{doc_id}")
        def get_document(doc_id: str, user: User, db: Db) -> DocumentOut:
            return _out(load(db, user, doc_id)[0])

        @router.put("/documents/{doc_id}")
        def update_document(doc_id: str, data: DocumentIn, user: User, db: Db) -> DocumentOut:
            doc, role = load(db, user, doc_id)
            editable(doc, role, user)
            if data.vehicle_id:
                check_vehicle(db, user, data.vehicle_id, doc.company_id)
            kind = KINDS[doc.kind]
            doc.data = clean(all_fields(kind, template_of(db, doc.company_id, kind.id)), data.data)
            doc.vehicle_id = data.vehicle_id
            doc.updated_at = _now()
            db.commit()
            return _out(doc)

        @router.delete("/documents/{doc_id}", status_code=status.HTTP_204_NO_CONTENT)
        def delete_document(doc_id: str, user: User, db: Db) -> Response:
            doc, role = load(db, user, doc_id)
            editable(doc, role, user)
            db.delete(doc)
            db.commit()
            return Response(status_code=status.HTTP_204_NO_CONTENT)

        def printable(db: Session, doc: Document) -> render.Doc:
            kind = KINDS[doc.kind]
            template = template_of(db, doc.company_id, doc.kind)
            profile = db.get(DocumentProfile, doc.company_id)
            logo = None
            if profile is not None and profile.logo:
                with PilImage.open(io.BytesIO(profile.logo)) as image:
                    logo = Image(profile.logo, image.width, image.height)
            return render.Doc(
                kind=kind,
                number=doc.number,
                data=doc.data or {},
                fields=fields_for(kind, template),
                terms=template.terms,
                logo=logo,
            )

        @router.get("/documents/{doc_id}/pdf")
        def document_pdf(doc_id: str, user: User, db: Db) -> Response:
            doc, _ = load(db, user, doc_id)
            return Response(
                render.to_pdf(printable(db, doc)),
                media_type="application/pdf",
                headers={"Content-Disposition": f'inline; filename="{_filename(doc)}.pdf"'},
            )

        @router.get("/documents/{doc_id}/html")
        def document_html(doc_id: str, user: User, db: Db) -> dict:
            """Strona do druku (pole ``html``) – przeglądarka wydrukuje ją albo zapisze jako PDF."""
            doc, _ = load(db, user, doc_id)
            return {"html": render.to_html(printable(db, doc)), "filename": _filename(doc)}

        @router.post("/documents/{doc_id}/link")
        def document_link(doc_id: str, user: User, db: Db) -> dict:
            """PDF pod krótkim linkiem (15 min) – do otwarcia w przeglądarce telefonu."""
            doc, _ = load(db, user, doc_id)
            name = _filename(doc)
            path = ctx.storage.share(
                db, render.to_pdf(printable(db, doc)), "application/pdf", f"{name}.pdf"
            )
            return {"path": path, "filename": name}

        class Feed:
            """Pulpit dyspozytora: dokumenty (CMR, zlecenia, karty drogowe) wystawione dziś."""

            def collect(self, db: Session, company_id: str, day: date) -> DashboardPart:
                start = datetime.combine(day, time.min, UTC)
                count = db.scalar(
                    select(func.count()).where(
                        Document.company_id == company_id, Document.created_at >= start
                    )
                )
                return DashboardPart(
                    kpis=[DashboardKpi(key="documents.today", value=count or 0, order=130)]
                )

        ctx.extensions.provide(DASHBOARD_FEED, Feed())
        ctx.api.include_router(router)
