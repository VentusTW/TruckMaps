"""Program administracyjny: wgląd we wszystkie dane i zmiany tylko za zgodą właściciela firmy.

Administratorów nadaje wyłącznie polecenie na serwerze (``python -m truckmaps.core.admin``),
nigdy API. Każde wywołanie ``/api/admin`` – także odrzucone – trafia do dziennika:
kto, rola, co (metoda, adres, parametry), kiedy, skąd (IP, urządzenie) i z jakim wynikiem;
zmiany dodatkowo z wartościami przed i po. Zmiany w danych firmy wymagają aktywnego
dostępu udzielonego przez właściciela (zakres, termin ważności, można go cofnąć), a firma
widzi w aplikacji każdą zmianę administratora.
"""

import argparse
import getpass
import uuid
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from enum import StrEnum
from pathlib import Path
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status
from pydantic import BaseModel, Field
from sqlalchemy import JSON, DateTime, ForeignKey, Integer, String, func, or_, select
from sqlalchemy.orm import Mapped, Session, mapped_column
from sqlalchemy.sql import Select

from truckmaps.core.companies import (
    BaseIn,
    Company,
    CompanyBase,
    CompanyIn,
    CompanyInvite,
    CompanyMember,
    Role,
    require_member,
)
from truckmaps.core.config import Settings, load_env_file
from truckmaps.core.currency import UserSettings
from truckmaps.core.db import Base, Database, get_session
from truckmaps.core.i18n import t
from truckmaps.core.inbox import Kind, mark_read, send
from truckmaps.core.releases import Release
from truckmaps.core.reports import DriverReport
from truckmaps.core.vehicles import VehicleProfile
from truckmaps.sdk import Principal

GRANT_MINUTES = 60
"""Tyle trwa dostęp po zgodzie właściciela; dłużej – tylko po przedłużeniu."""
MAX_GRANT_MINUTES = 8 * 60
PAGE_LIMIT = 200
# Wartości ``amr`` (RFC 8176, Zitadel) oznaczające logowanie z drugim składnikiem.
MFA_METHODS = {"mfa", "otp", "u2f", "hwk", "swk"}


class AdminRole(StrEnum):
    FULL = "full"
    """Wgląd we wszystko i zmiany – te w firmie tylko za zgodą właściciela."""
    SUPPORT = "support"
    """Wsparcie: tylko odczyt."""


class Scope(StrEnum):
    """Co właściciel pozwala administratorowi zmieniać w firmie."""

    COMPANY = "company"
    """Dane firmy i stawki."""
    BASES = "bases"


def _now() -> datetime:
    return datetime.now(UTC)


def _aware(moment: datetime) -> datetime:
    # SQLite (testy) zwraca daty bez strefy czasowej.
    return moment if moment.tzinfo else moment.replace(tzinfo=UTC)


class AdminAccount(Base):
    __tablename__ = "admin_accounts"

    subject: Mapped[str] = mapped_column(String(255), primary_key=True)
    """Konto w Zitadelu (``sub``) – hasło i drugi składnik są tylko tam."""
    name: Mapped[str] = mapped_column(String(200), default="")
    role: Mapped[str] = mapped_column(String(10))
    created_by: Mapped[str] = mapped_column(String(255))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    disabled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class AuditEntry(Base):
    """Dziennik działań administratorów. Tylko dopisywanie – API niczego tu nie zmienia."""

    __tablename__ = "admin_audit_log"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now, index=True)
    subject: Mapped[str] = mapped_column(String(255), default="", index=True)
    """Puste – nie udało się ustalić konta (np. zły token)."""
    role: Mapped[str] = mapped_column(String(10), default="")
    method: Mapped[str] = mapped_column(String(10))
    path: Mapped[str] = mapped_column(String(500))
    query: Mapped[str] = mapped_column(String(1000), default="")
    status_code: Mapped[int] = mapped_column(Integer)
    ip: Mapped[str] = mapped_column(String(64), default="")
    user_agent: Mapped[str] = mapped_column(String(300), default="")
    action: Mapped[str] = mapped_column(String(50), default="", index=True)
    """Rodzaj zmiany, np. ``company.update``; puste – sam odczyt."""
    company_id: Mapped[str | None] = mapped_column(String(36), index=True)
    changes: Mapped[dict | None] = mapped_column(JSON)
    """``{"pole": [przed, po]}``."""


class GrantState(StrEnum):
    PENDING = "pending"
    """Prośba administratora czeka na decyzję właściciela."""
    ACTIVE = "active"
    REJECTED = "rejected"
    CLOSED = "closed"
    """Zamknięty przed czasem – przez właściciela albo administratora."""
    EXPIRED = "expired"


class AccessGrant(Base):
    """Dostęp administratora do zmian w firmie: prośba administratora i zgoda właściciela."""

    __tablename__ = "company_access_grants"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    company_id: Mapped[str] = mapped_column(
        ForeignKey("companies.id", ondelete="CASCADE"), index=True
    )
    scopes: Mapped[list] = mapped_column(JSON)
    note: Mapped[str] = mapped_column(String(300), default="")
    """Powód prośby administratora albo notatka właściciela."""
    requested_by: Mapped[str | None] = mapped_column(String(255))
    """Administrator, który poprosił; brak – właściciel udzielił dostępu sam."""
    requested_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    granted_by: Mapped[str | None] = mapped_column(String(255))
    granted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    revoked_by: Mapped[str | None] = mapped_column(String(255))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    def state(self, moment: datetime) -> GrantState:
        if self.granted_at is None:
            return GrantState.REJECTED if self.revoked_at else GrantState.PENDING
        if self.revoked_at is not None:
            return GrantState.CLOSED
        if _aware(self.expires_at) <= moment:
            return GrantState.EXPIRED
        return GrantState.ACTIVE

    def active(self, moment: datetime) -> bool:
        return self.state(moment) == GrantState.ACTIVE


Minutes = Annotated[int, Field(ge=15, le=MAX_GRANT_MINUTES, description="Na ile minut")]


class GrantIn(BaseModel):
    scopes: list[Scope] = Field(min_length=1)
    minutes: Minutes = GRANT_MINUTES
    note: str = Field(default="", max_length=300, description="Np. numer zgłoszenia do wsparcia")


class RequestIn(BaseModel):
    scopes: list[Scope] = Field(min_length=1)
    note: str = Field(min_length=3, max_length=300, description="Co i dlaczego trzeba zmienić")


class MinutesIn(BaseModel):
    minutes: Minutes = GRANT_MINUTES


class GrantOut(BaseModel):
    id: str
    company_id: str
    scopes: list[Scope]
    note: str
    state: GrantState
    requested_by: str | None
    """Imię administratora, który poprosił."""
    requested_at: datetime | None
    granted_at: datetime | None
    expires_at: datetime | None
    revoked_at: datetime | None
    active: bool


class ChangeOut(BaseModel):
    """Zmiana administratora widoczna dla firmy."""

    at: datetime
    admin: str
    action: str
    changes: dict


class AdminAccess(BaseModel):
    grants: list[GrantOut]
    changes: list[ChangeOut]


def _maybe(moment: datetime | None) -> datetime | None:
    return moment and _aware(moment)


def _grant_out(db: Session, grant: AccessGrant, moment: datetime) -> GrantOut:
    admin = grant.requested_by and db.get(AdminAccount, grant.requested_by)
    state = grant.state(moment)
    return GrantOut(
        id=grant.id,
        company_id=grant.company_id,
        scopes=grant.scopes,
        note=grant.note,
        state=state,
        requested_by=(admin.name or admin.subject) if admin else grant.requested_by,
        requested_at=_maybe(grant.requested_at),
        granted_at=_maybe(grant.granted_at),
        expires_at=_maybe(grant.expires_at),
        revoked_at=_maybe(grant.revoked_at),
        active=state == GrantState.ACTIVE,
    )


def describe_grant(db: Session, grant_id: str) -> dict | None:
    """Stan dostępu dla skrzynki wiadomości."""
    grant = db.get(AccessGrant, grant_id)
    return grant and _grant_out(db, grant, _now()).model_dump(mode="json")


def _owners(db: Session, company_id: str) -> list[str]:
    return list(
        db.scalars(
            select(CompanyMember.subject).where(
                CompanyMember.company_id == company_id, CompanyMember.role == Role.OWNER
            )
        )
    )


def has_mfa(user: Principal) -> bool:
    amr = user.claims.get("amr") or []
    return bool(MFA_METHODS & {str(method).lower() for method in amr})


class AuditMiddleware:
    """Zapisuje w dzienniku każde wywołanie ``/api/admin`` razem z wynikiem."""

    def __init__(self, app) -> None:
        self.app = app

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] != "http" or not scope["path"].startswith("/api/admin"):
            await self.app(scope, receive, send)
            return
        state = scope.setdefault("state", {})
        result = {"status": 500}

        async def send_with_status(message) -> None:
            if message["type"] == "http.response.start":
                result["status"] = message["status"]
            await send(message)

        try:
            await self.app(scope, receive, send_with_status)
        finally:
            database: Database | None = scope["app"].state.database
            if database is not None:
                _record(database, scope, state, result["status"])


def _record(database: Database, scope, state: dict, status_code: int) -> None:
    headers = {k.decode("latin-1"): v.decode("latin-1") for k, v in scope.get("headers", [])}
    client = scope.get("client")
    audit = state.get("audit", {})
    # Zmiana, której nie zapisano w bazie (błąd), nie jest zmianą dla firmy.
    changed = status_code < 400
    with database.session() as db:
        db.add(
            AuditEntry(
                subject=state.get("admin_subject", ""),
                role=state.get("admin_role", ""),
                method=scope["method"],
                path=scope["path"][:500],
                query=scope.get("query_string", b"").decode("latin-1")[:1000],
                status_code=status_code,
                ip=(client[0] if client else "")[:64],
                user_agent=headers.get("user-agent", "")[:300],
                action=audit.get("action", "") if changed else "",
                company_id=audit.get("company_id"),
                changes=audit.get("changes") if changed else None,
            )
        )
        db.commit()


def _audit(request: Request, action: str, company_id: str | None, changes: dict) -> None:
    request.state.audit = {"action": action, "company_id": company_id, "changes": changes}


def _apply(target: Any, data: dict) -> dict:
    """Przypisuje pola i zwraca różnice ``{"pole": [przed, po]}``."""
    changes = {}
    for field, value in data.items():
        before = getattr(target, field)
        if before != value:
            changes[field] = [before, value]
            setattr(target, field, value)
    return changes


def _page(db: Session, query: Select, limit: int, offset: int, row: Callable) -> dict:
    total = db.scalar(select(func.count()).select_from(query.order_by(None).subquery()))
    items = db.execute(query.limit(limit).offset(offset))
    return {"total": total, "items": [row(*r) for r in items]}


def _like(text: str) -> str:
    escaped = text.strip().replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{escaped}%"


def _matches(q: str | None, *columns) -> list:
    if not q or not q.strip():
        return []
    return [or_(*(func.lower(c).like(_like(q.lower()), escape="\\") for c in columns))]


def build_router(current_user, settings: Settings, licensing) -> APIRouter:
    router = APIRouter(tags=["admin"])
    User = Annotated[Principal, Depends(current_user)]
    Db = Annotated[Session, Depends(get_session)]
    Limit = Annotated[int, Query(ge=1, le=PAGE_LIMIT)]
    Offset = Annotated[int, Query(ge=0)]

    def admin(request: Request, user: User, db: Db) -> AdminAccount:
        request.state.admin_subject = user.subject
        account = db.get(AdminAccount, user.subject)
        if account is None or account.disabled_at is not None:
            raise HTTPException(status.HTTP_403_FORBIDDEN, t("error.admin_required"))
        request.state.admin_role = account.role
        if settings.admin_require_mfa and not has_mfa(user):
            raise HTTPException(status.HTTP_403_FORBIDDEN, t("error.admin_mfa_required"))
        return account

    def full_admin(account: Annotated[AdminAccount, Depends(admin)]) -> AdminAccount:
        if account.role != AdminRole.FULL:
            raise HTTPException(status.HTTP_403_FORBIDDEN, t("error.admin_read_only"))
        return account

    Admin = Annotated[AdminAccount, Depends(admin)]
    FullAdmin = Annotated[AdminAccount, Depends(full_admin)]

    def require_grant(db: Session, company_id: str, scope: Scope) -> None:
        if db.get(Company, company_id) is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("error.company_not_found"))
        moment = _now()
        grants = db.scalars(select(AccessGrant).where(AccessGrant.company_id == company_id))
        if not any(g.active(moment) and scope in g.scopes for g in grants):
            raise HTTPException(status.HTTP_403_FORBIDDEN, t("error.admin_access_not_granted"))

    # --- Program administracyjny --------------------------------------------------------

    @router.get("/api/admin/me")
    def whoami(account: Admin) -> dict:
        return {"subject": account.subject, "name": account.name, "role": account.role}

    @router.get("/api/admin/accounts")
    def accounts(
        account: Admin, db: Db, q: str | None = None, limit: Limit = 50, offset: Offset = 0
    ) -> dict:
        """Ustawienia kont (bez haseł – te są tylko u dostawcy logowania)."""
        companies = (
            select(func.count())
            .where(CompanyMember.subject == UserSettings.subject)
            .scalar_subquery()
        )
        query = (
            select(UserSettings, companies)
            .where(*_matches(q, UserSettings.subject, UserSettings.display_name))
            .order_by(UserSettings.display_name, UserSettings.subject)
        )
        return _page(
            db,
            query,
            limit,
            offset,
            lambda s, n: {
                "subject": s.subject,
                "display_name": s.display_name,
                "language": s.language,
                "currency": s.currency,
                "onboarded": s.onboarded,
                "companies": n,
            },
        )

    @router.get("/api/admin/companies")
    def companies(
        account: Admin, db: Db, q: str | None = None, limit: Limit = 50, offset: Offset = 0
    ) -> dict:
        members = (
            select(func.count()).where(CompanyMember.company_id == Company.id).scalar_subquery()
        )
        query = (
            select(Company, members)
            .where(*_matches(q, Company.name, Company.tax_id, Company.id))
            .order_by(Company.name)
        )
        moment = _now()
        page = _page(db, query, limit, offset, lambda c, n: (c, n))
        ids = [c.id for c, _ in page["items"]]
        granted = {
            g.company_id
            for g in db.scalars(select(AccessGrant).where(AccessGrant.company_id.in_(ids)))
            if g.active(moment)
        }
        page["items"] = [
            {**_company(c), "members": n, "access_granted": c.id in granted}
            for c, n in page["items"]
        ]
        return page

    @router.get("/api/admin/companies/{company_id}")
    def company(company_id: str, account: Admin, db: Db) -> dict:
        found = db.get(Company, company_id)
        if found is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("error.company_not_found"))
        moment = _now()
        grants = db.scalars(
            select(AccessGrant)
            .where(AccessGrant.company_id == company_id)
            .order_by(AccessGrant.granted_at.desc())
        )
        return {
            **_company(found),
            "grants": [_grant_out(db, g, moment).model_dump() for g in grants],
        }

    @router.get("/api/admin/members")
    def members(
        account: Admin,
        db: Db,
        q: str | None = None,
        company_id: str | None = None,
        role: Role | None = None,
        limit: Limit = 50,
        offset: Offset = 0,
    ) -> dict:
        query = (
            select(CompanyMember, Company.name)
            .join(Company, Company.id == CompanyMember.company_id)
            .where(*_matches(q, CompanyMember.display_name, CompanyMember.subject))
            .order_by(Company.name, CompanyMember.display_name)
        )
        if company_id:
            query = query.where(CompanyMember.company_id == company_id)
        if role:
            query = query.where(CompanyMember.role == role)
        return _page(
            db,
            query,
            limit,
            offset,
            lambda m, name: {
                "id": m.id,
                "company_id": m.company_id,
                "company_name": name,
                "subject": m.subject,
                "display_name": m.display_name,
                "role": m.role,
                "joined_at": m.joined_at,
            },
        )

    @router.get("/api/admin/invites")
    def invites(
        account: Admin,
        db: Db,
        company_id: str | None = None,
        active: bool | None = None,
        limit: Limit = 50,
        offset: Offset = 0,
    ) -> dict:
        query = (
            select(CompanyInvite, Company.name)
            .join(Company, Company.id == CompanyInvite.company_id)
            .order_by(CompanyInvite.created_at.desc())
        )
        if company_id:
            query = query.where(CompanyInvite.company_id == company_id)
        if active is not None:
            moment = _now()
            query = query.where(
                CompanyInvite.expires_at > moment if active else CompanyInvite.expires_at <= moment
            )
        # Kod zaproszenia to dostęp do firmy – administrator widzi tylko jego początek.
        return _page(
            db,
            query,
            limit,
            offset,
            lambda i, name: {
                "code": i.code[:2] + "…",
                "company_id": i.company_id,
                "company_name": name,
                "role": i.role,
                "note": i.note,
                "created_by": i.created_by,
                "created_at": i.created_at,
                "expires_at": i.expires_at,
            },
        )

    @router.get("/api/admin/bases")
    def bases(
        account: Admin,
        db: Db,
        q: str | None = None,
        company_id: str | None = None,
        limit: Limit = 50,
        offset: Offset = 0,
    ) -> dict:
        query = (
            select(CompanyBase, Company.name)
            .join(Company, Company.id == CompanyBase.company_id)
            .where(*_matches(q, CompanyBase.name, CompanyBase.label))
            .order_by(Company.name, CompanyBase.name)
        )
        if company_id:
            query = query.where(CompanyBase.company_id == company_id)
        return _page(
            db,
            query,
            limit,
            offset,
            lambda b, name: {
                "id": b.id,
                "company_id": b.company_id,
                "company_name": name,
                "name": b.name,
                "label": b.label,
                "lat": b.lat,
                "lon": b.lon,
            },
        )

    @router.get("/api/admin/vehicles")
    def vehicles(
        account: Admin,
        db: Db,
        q: str | None = None,
        company_id: str | None = None,
        owner: str | None = None,
        limit: Limit = 50,
        offset: Offset = 0,
    ) -> dict:
        query = (
            select(VehicleProfile, Company.name)
            .outerjoin(Company, Company.id == VehicleProfile.company_id)
            .where(*_matches(q, VehicleProfile.name, VehicleProfile.plate))
            .order_by(VehicleProfile.name)
        )
        if company_id:
            query = query.where(VehicleProfile.company_id == company_id)
        if owner:
            query = query.where(VehicleProfile.owner_subject == owner)
        return _page(
            db,
            query,
            limit,
            offset,
            lambda v, name: {
                "id": v.id,
                "name": v.name,
                "plate": v.plate,
                "owner_subject": v.owner_subject,
                "company_id": v.company_id,
                "company_name": name,
                "height_m": v.height_m,
                "width_m": v.width_m,
                "length_m": v.length_m,
                "gvw_t": v.gvw_t,
                "hazmat": v.hazmat,
                "updated_at": v.updated_at,
            },
        )

    @router.get("/api/admin/reports")
    def reports(
        account: Admin,
        db: Db,
        q: str | None = None,
        kind: str | None = None,
        limit: Limit = 50,
        offset: Offset = 0,
    ) -> dict:
        query = (
            select(DriverReport)
            .where(*_matches(q, DriverReport.note, DriverReport.subject))
            .order_by(DriverReport.created_at.desc())
        )
        if kind:
            query = query.where(DriverReport.kind == kind)
        return _page(
            db,
            query,
            limit,
            offset,
            lambda r: {
                "id": r.id,
                "subject": r.subject,
                "kind": r.kind,
                "lat": r.lat,
                "lon": r.lon,
                "note": r.note,
                "value": r.value,
                "score": r.score,
                "created_at": r.created_at,
                "confirmed_at": r.confirmed_at,
            },
        )

    @router.get("/api/admin/releases")
    def releases(
        account: Admin,
        db: Db,
        kind: str | None = None,
        state: str | None = Query(default=None, alias="status"),
        limit: Limit = 50,
        offset: Offset = 0,
    ) -> dict:
        query = select(Release).order_by(Release.published_at.desc())
        if kind:
            query = query.where(Release.kind == kind)
        if state:
            query = query.where(Release.status == state)
        return _page(
            db,
            query,
            limit,
            offset,
            lambda r: {
                "id": r.id,
                "kind": r.kind,
                "name": r.name,
                "platform": r.platform,
                "version": r.version,
                "status": r.status,
                "rollout": r.rollout,
                "size_bytes": r.size_bytes,
                "published_at": r.published_at,
            },
        )

    @router.get("/api/admin/licenses")
    def licenses(account: Admin, q: str | None = None) -> dict:
        """Licencje z konfiguracji serwera (tymczasowe – do czasu subskrypcji)."""
        rows = [
            {"subject": subject, "modules": sorted(modules)}
            for subject, modules in sorted(licensing.assignments().items())
            if not q or q.strip().lower() in subject.lower()
        ]
        return {"total": len(rows), "items": rows, "grant_all": licensing.grants_all}

    @router.get("/api/admin/audit")
    def audit(
        account: Admin,
        db: Db,
        subject: str | None = None,
        company_id: str | None = None,
        changes_only: bool = False,
        limit: Limit = 50,
        offset: Offset = 0,
    ) -> dict:
        query = select(AuditEntry).order_by(AuditEntry.id.desc())
        if subject:
            query = query.where(AuditEntry.subject == subject)
        if company_id:
            query = query.where(AuditEntry.company_id == company_id)
        if changes_only:
            query = query.where(AuditEntry.action != "")
        return _page(
            db,
            query,
            limit,
            offset,
            lambda e: {
                "id": e.id,
                "at": e.at,
                "subject": e.subject,
                "role": e.role,
                "method": e.method,
                "path": e.path,
                "query": e.query,
                "status_code": e.status_code,
                "ip": e.ip,
                "user_agent": e.user_agent,
                "action": e.action,
                "company_id": e.company_id,
                "changes": e.changes,
            },
        )

    @router.put("/api/admin/companies/{company_id}")
    def update_company(
        company_id: str, data: CompanyIn, request: Request, account: FullAdmin, db: Db
    ) -> dict:
        require_grant(db, company_id, Scope.COMPANY)
        found = db.get(Company, company_id)
        _audit(request, "company.update", company_id, _apply(found, data.model_dump()))
        db.commit()
        return _company(found)

    @router.put("/api/admin/companies/{company_id}/bases/{base_id}")
    def update_base(
        company_id: str, base_id: str, data: BaseIn, request: Request, account: FullAdmin, db: Db
    ) -> dict:
        require_grant(db, company_id, Scope.BASES)
        base = db.get(CompanyBase, base_id)
        if base is None or base.company_id != company_id:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("error.base_not_found"))
        name = base.name
        changes = _apply(base, data.model_dump())
        # Nazwa bazy zawsze w dzienniku, żeby firma wiedziała, której dotyczy zmiana.
        _audit(request, "base.update", company_id, {"base": [name, base.name], **changes})
        db.commit()
        return {"id": base.id, **data.model_dump()}

    # --- Prośba o dostęp: administrator prosi, właściciel decyduje w skrzynce -----------

    def my_grant(db: Session, grant_id: str, account: AdminAccount) -> AccessGrant:
        found = db.get(AccessGrant, grant_id)
        if found is None or found.requested_by != account.subject:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("error.grant_not_found"))
        return found

    @router.post(
        "/api/admin/companies/{company_id}/access-requests", status_code=status.HTTP_201_CREATED
    )
    def request_access(company_id: str, data: RequestIn, account: FullAdmin, db: Db) -> GrantOut:
        if db.get(Company, company_id) is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("error.company_not_found"))
        moment = _now()
        created = AccessGrant(
            company_id=company_id,
            scopes=sorted(set(data.scopes)),
            note=data.note.strip(),
            requested_by=account.subject,
            requested_at=moment,
        )
        db.add(created)
        db.flush()
        send(
            db,
            _owners(db, company_id),
            Kind.ACCESS_REQUEST,
            sender_name=account.name,
            company_id=company_id,
            grant_id=created.id,
            data={"scopes": created.scopes, "note": created.note},
        )
        db.commit()
        return _grant_out(db, created, moment)

    @router.get("/api/admin/grants")
    def my_grants(account: Admin, db: Db) -> list[dict]:
        """Prośby i dostępy tego administratora – do odliczania czasu w programie."""
        moment = _now()
        rows = db.execute(
            select(AccessGrant, Company.name)
            .join(Company, Company.id == AccessGrant.company_id)
            .where(AccessGrant.requested_by == account.subject)
            .order_by(AccessGrant.requested_at.desc())
            .limit(PAGE_LIMIT)
        )
        return [
            {**_grant_out(db, g, moment).model_dump(), "company_name": name} for g, name in rows
        ]

    @router.post("/api/admin/grants/{grant_id}/close", status_code=status.HTTP_204_NO_CONTENT)
    def close_grant(grant_id: str, account: Admin, db: Db) -> Response:
        """Administrator skończył zmiany – dostęp zamknięty przed czasem."""
        found = my_grant(db, grant_id, account)
        if found.state(_now()) in {GrantState.ACTIVE, GrantState.PENDING}:
            found.revoked_at = _now()
            found.revoked_by = account.subject
            send(
                db,
                _owners(db, found.company_id),
                Kind.ACCESS_CLOSED,
                sender_name=account.name,
                company_id=found.company_id,
                grant_id=found.id,
            )
            db.commit()
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @router.post(
        "/api/admin/grants/{grant_id}/extension-request", status_code=status.HTTP_204_NO_CONTENT
    )
    def request_extension(grant_id: str, data: MinutesIn, account: Admin, db: Db) -> Response:
        found = my_grant(db, grant_id, account)
        if not found.active(_now()):
            raise HTTPException(status.HTTP_409_CONFLICT, t("error.grant_not_active"))
        send(
            db,
            _owners(db, found.company_id),
            Kind.EXTENSION_REQUEST,
            sender_name=account.name,
            company_id=found.company_id,
            grant_id=found.id,
            data={"minutes": data.minutes},
        )
        db.commit()
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    # --- Właściciel firmy: zgoda na zmiany administratora ------------------------------

    def owners_grant(db: Session, company_id: str, grant_id: str, user: Principal) -> AccessGrant:
        require_member(db, company_id, user, {Role.OWNER})
        found = db.get(AccessGrant, grant_id)
        if found is None or found.company_id != company_id:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("error.grant_not_found"))
        return found

    @router.get("/api/companies/{company_id}/admin-access")
    def access(company_id: str, user: User, db: Db) -> AdminAccess:
        require_member(db, company_id, user, {Role.OWNER})
        moment = _now()
        grants = db.scalars(
            select(AccessGrant)
            .where(AccessGrant.company_id == company_id)
            .order_by(func.coalesce(AccessGrant.requested_at, AccessGrant.granted_at).desc())
        )
        entries = db.execute(
            select(AuditEntry, AdminAccount.name)
            .outerjoin(AdminAccount, AdminAccount.subject == AuditEntry.subject)
            .where(AuditEntry.company_id == company_id, AuditEntry.action != "")
            .order_by(AuditEntry.id.desc())
            .limit(PAGE_LIMIT)
        )
        return AdminAccess(
            grants=[_grant_out(db, g, moment) for g in grants],
            changes=[
                ChangeOut(
                    at=_aware(e.at),
                    admin=name or e.subject,
                    action=e.action,
                    changes=e.changes or {},
                )
                for e, name in entries
            ],
        )

    @router.post("/api/companies/{company_id}/admin-access", status_code=status.HTTP_201_CREATED)
    def grant(company_id: str, data: GrantIn, user: User, db: Db) -> GrantOut:
        """Właściciel udziela dostępu sam, bez prośby administratora."""
        require_member(db, company_id, user, {Role.OWNER})
        moment = _now()
        created = AccessGrant(
            company_id=company_id,
            scopes=sorted(set(data.scopes)),
            note=data.note.strip(),
            granted_by=user.subject,
            granted_at=moment,
            expires_at=moment + timedelta(minutes=data.minutes),
        )
        db.add(created)
        db.commit()
        return _grant_out(db, created, moment)

    @router.post("/api/companies/{company_id}/admin-access/{grant_id}/accept")
    def accept(company_id: str, grant_id: str, data: MinutesIn, user: User, db: Db) -> GrantOut:
        found = owners_grant(db, company_id, grant_id, user)
        moment = _now()
        if found.state(moment) != GrantState.PENDING:
            raise HTTPException(status.HTTP_409_CONFLICT, t("error.grant_not_pending"))
        found.granted_by = user.subject
        found.granted_at = moment
        found.expires_at = moment + timedelta(minutes=data.minutes)
        mark_read(db, found.id, user.subject)
        db.commit()
        return _grant_out(db, found, moment)

    @router.post("/api/companies/{company_id}/admin-access/{grant_id}/reject")
    def reject(company_id: str, grant_id: str, user: User, db: Db) -> GrantOut:
        found = owners_grant(db, company_id, grant_id, user)
        moment = _now()
        if found.state(moment) != GrantState.PENDING:
            raise HTTPException(status.HTTP_409_CONFLICT, t("error.grant_not_pending"))
        found.revoked_at = moment
        found.revoked_by = user.subject
        mark_read(db, found.id, user.subject)
        db.commit()
        return _grant_out(db, found, moment)

    @router.post("/api/companies/{company_id}/admin-access/{grant_id}/extend")
    def extend(company_id: str, grant_id: str, data: MinutesIn, user: User, db: Db) -> GrantOut:
        found = owners_grant(db, company_id, grant_id, user)
        moment = _now()
        if not found.active(moment):
            raise HTTPException(status.HTTP_409_CONFLICT, t("error.grant_not_active"))
        found.expires_at = _aware(found.expires_at) + timedelta(minutes=data.minutes)
        if found.expires_at - moment > timedelta(minutes=MAX_GRANT_MINUTES):
            found.expires_at = moment + timedelta(minutes=MAX_GRANT_MINUTES)
        mark_read(db, found.id, user.subject)
        db.commit()
        return _grant_out(db, found, moment)

    @router.delete(
        "/api/companies/{company_id}/admin-access/{grant_id}",
        status_code=status.HTTP_204_NO_CONTENT,
    )
    def revoke(company_id: str, grant_id: str, user: User, db: Db) -> Response:
        found = owners_grant(db, company_id, grant_id, user)
        if found.revoked_at is None:
            found.revoked_at = _now()
            found.revoked_by = user.subject
            mark_read(db, found.id, user.subject)
            db.commit()
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    return router


def _company(company: Company) -> dict:
    return {
        "id": company.id,
        "name": company.name,
        "tax_id": company.tax_id,
        "cost_per_km": company.cost_per_km,
        "cost_per_hour": company.cost_per_hour,
        "cost_currency": company.cost_currency,
        "created_at": company.created_at,
    }


def main(argv: list[str] | None = None, database: Database | None = None) -> None:
    """Konta administratorów: nadanie, zmiana roli, wyłączenie, lista. Tylko na serwerze."""
    parser = argparse.ArgumentParser(prog="python -m truckmaps.core.admin")
    commands = parser.add_subparsers(dest="command", required=True)
    add = commands.add_parser("add", help="nowy administrator albo zmiana roli")
    add.add_argument("subject", help="identyfikator konta w Zitadelu (sub)")
    add.add_argument("--role", choices=list(AdminRole), default=AdminRole.SUPPORT)
    add.add_argument("--name", default="")
    commands.add_parser("disable", help="wyłączenie konta").add_argument("subject")
    commands.add_parser("list")
    args = parser.parse_args(argv)

    if database is None:
        load_env_file(Path.cwd() / ".env")
        url = Settings.from_env().database_url
        if not url:
            raise SystemExit(t("error.database_not_configured"))
        database = Database(url)
    with database.session() as db:
        if args.command == "list":
            for a in db.scalars(select(AdminAccount).order_by(AdminAccount.created_at)):
                state = "disabled" if a.disabled_at else a.role
                print(f"{a.subject:<36} {state:<9} {a.name}")
            return
        account = db.get(AdminAccount, args.subject)
        operator = f"cli:{getpass.getuser()}"
        if args.command == "add":
            before = account and [account.role, account.disabled_at is None]
            if account is None:
                account = AdminAccount(subject=args.subject, created_by=operator)
                db.add(account)
            account.role = args.role
            account.name = args.name or account.name
            account.disabled_at = None
            changes = {"role": [before and before[0], args.role]}
        else:
            if account is None:
                raise SystemExit(t("admin.not_found", subject=args.subject))
            account.disabled_at = _now()
            changes = {"active": [True, False]}
        # Zmiany kont administratorów też trafiają do dziennika.
        db.add(
            AuditEntry(
                subject=operator,
                method="CLI",
                path=f"admin {args.command} {args.subject}",
                status_code=0,
                ip="local",
                action=f"admin.{args.command}",
                changes=changes,
            )
        )
        db.commit()
        print(t("admin.saved", subject=args.subject))


if __name__ == "__main__":
    main()
