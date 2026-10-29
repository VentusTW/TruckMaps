"""Firmy i floty: członkowie z rolami, zaproszenia kodem, wspólne pojazdy.

Konto (logowanie) zostaje u dostawcy logowania, a przynależność do firm trzymamy
u siebie. Dzięki temu kierowca, który założył konto sam, dołącza do firmy kodem
zaproszenia i może należeć do kilku firm naraz.
"""

import secrets
import uuid
from datetime import UTC, datetime, timedelta
from enum import StrEnum
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Response, status
from pydantic import BaseModel, ConfigDict, Field, StringConstraints
from sqlalchemy import DateTime, ForeignKey, String, UniqueConstraint, func, select, update
from sqlalchemy.orm import Mapped, Session, mapped_column

from truckmaps.core.costs import CostRates
from truckmaps.core.db import Base, get_session
from truckmaps.sdk import Principal

INVITE_VALID_DAYS = 7
# Bez znaków łatwych do pomylenia (0/O, 1/I/L) – kod bywa przepisywany z telefonu.
INVITE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
INVITE_LENGTH = 8


class Role(StrEnum):
    OWNER = "owner"
    """Wszystko, w tym członkowie i ich role."""
    DISPATCHER = "dispatcher"
    """Pojazdy firmy i zapraszanie kierowców."""
    DRIVER = "driver"
    """Korzysta z pojazdów firmy."""


MANAGES_VEHICLES = {Role.OWNER, Role.DISPATCHER}


def _now() -> datetime:
    return datetime.now(UTC)


def _id() -> str:
    return str(uuid.uuid4())


class Company(Base):
    __tablename__ = "companies"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_id)
    name: Mapped[str] = mapped_column(String(200))
    tax_id: Mapped[str | None] = mapped_column(String(30))
    cost_eur_per_km: Mapped[float | None]
    """Stawki domyślne dla pojazdów firmy, które nie mają własnych."""
    cost_eur_per_hour: Mapped[float | None]
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class CompanyMember(Base):
    __tablename__ = "company_members"
    __table_args__ = (UniqueConstraint("company_id", "subject"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_id)
    company_id: Mapped[str] = mapped_column(ForeignKey("companies.id", ondelete="CASCADE"))
    subject: Mapped[str] = mapped_column(String(255), index=True)
    display_name: Mapped[str] = mapped_column(String(200))
    role: Mapped[str] = mapped_column(String(20))
    joined_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class CompanyBase(Base):
    """Baza firmy – miejsce, skąd wyjeżdżają pojazdy (podpowiadane w polach adresu)."""

    __tablename__ = "company_bases"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_id)
    company_id: Mapped[str] = mapped_column(ForeignKey("companies.id", ondelete="CASCADE"))
    name: Mapped[str] = mapped_column(String(100))
    label: Mapped[str] = mapped_column(String(300), default="")
    lat: Mapped[float]
    lon: Mapped[float]
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class CompanyInvite(Base):
    __tablename__ = "company_invites"

    code: Mapped[str] = mapped_column(String(16), primary_key=True)
    company_id: Mapped[str] = mapped_column(ForeignKey("companies.id", ondelete="CASCADE"))
    role: Mapped[str] = mapped_column(String(20))
    note: Mapped[str] = mapped_column(String(200), default="")
    created_by: Mapped[str] = mapped_column(String(255))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class CompanyIn(CostRates):
    name: Annotated[str, StringConstraints(strip_whitespace=True, min_length=2, max_length=200)] = (
        Field(examples=["Trans-Miś Sp. z o.o."])
    )
    tax_id: str | None = Field(default=None, max_length=30, description="NIP / VAT ID")


class CompanyCreate(CompanyIn):
    display_name: str | None = Field(
        default=None, max_length=200, description="Jak widzą cię inni członkowie firmy"
    )


class CompanyOut(CompanyIn):
    model_config = ConfigDict(from_attributes=True)

    id: str
    role: Role
    """Rola zalogowanego użytkownika w tej firmie."""


class MemberOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    display_name: str
    role: Role
    joined_at: datetime
    is_me: bool = False


class CompanyDetails(CompanyOut):
    members: list[MemberOut]


class InviteIn(BaseModel):
    role: Role = Role.DRIVER
    note: str = Field(default="", max_length=200, description="Dla kogo, np. „Marek – DW 12345”")


class InviteOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    code: str
    role: Role
    note: str
    expires_at: datetime


class BaseIn(BaseModel):
    name: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=100)] = (
        Field(examples=["Baza Tarnów"])
    )
    label: str = Field(default="", max_length=300, description="Adres, np. z wyszukiwarki")
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)


class BaseOut(BaseIn):
    model_config = ConfigDict(from_attributes=True)

    id: str
    company_id: str
    company_name: str = ""


class JoinIn(BaseModel):
    display_name: str | None = Field(default=None, max_length=200)


class RoleIn(BaseModel):
    role: Role


def membership(db: Session, company_id: str, user: Principal) -> CompanyMember | None:
    return db.scalar(
        select(CompanyMember).where(
            CompanyMember.company_id == company_id, CompanyMember.subject == user.subject
        )
    )


def company_ids(db: Session, user: Principal) -> dict[str, Role]:
    """Firmy użytkownika i jego rola w każdej z nich."""
    rows = db.execute(
        select(CompanyMember.company_id, CompanyMember.role).where(
            CompanyMember.subject == user.subject
        )
    )
    return {company_id: Role(role) for company_id, role in rows}


def require_member(
    db: Session, company_id: str, user: Principal, roles: set[Role] | None = None
) -> CompanyMember:
    """Członek firmy z jedną z ``roles``; obcy dostaje 404, za niska rola – 403."""
    member = membership(db, company_id, user)
    if member is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Nie znaleziono firmy.")
    if roles is not None and Role(member.role) not in roles:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Twoja rola w firmie na to nie pozwala.")
    return member


def _display_name(requested: str | None, user: Principal) -> str:
    claims = user.claims
    name = requested or claims.get("name") or claims.get("email")
    name = name or claims.get("preferred_username")
    return (name or f"Użytkownik {user.subject[-6:]}").strip()[:200]


def _owners(db: Session, company_id: str) -> int:
    return db.scalar(
        select(func.count()).where(
            CompanyMember.company_id == company_id, CompanyMember.role == Role.OWNER
        )
    )


def _new_code() -> str:
    return "".join(secrets.choice(INVITE_ALPHABET) for _ in range(INVITE_LENGTH))


def _normalize_code(code: str) -> str:
    return code.strip().upper().replace("-", "").replace(" ", "")


def _aware(moment: datetime) -> datetime:
    # SQLite (testy) zwraca daty bez strefy czasowej.
    return moment if moment.tzinfo else moment.replace(tzinfo=UTC)


def build_router(current_user) -> APIRouter:
    router = APIRouter(tags=["companies"])
    User = Annotated[Principal, Depends(current_user)]
    Db = Annotated[Session, Depends(get_session)]

    def details(db: Session, company: Company, me: CompanyMember) -> CompanyDetails:
        members = db.scalars(
            select(CompanyMember)
            .where(CompanyMember.company_id == company.id)
            .order_by(CompanyMember.joined_at)
        )
        return CompanyDetails(
            **_fields(company),
            role=Role(me.role),
            members=[
                MemberOut.model_validate(m).model_copy(update={"is_me": m.id == me.id})
                for m in members
            ],
        )

    @router.get("/api/companies")
    def list_companies(user: User, db: Db) -> list[CompanyOut]:
        rows = db.execute(
            select(Company, CompanyMember.role)
            .join(CompanyMember, CompanyMember.company_id == Company.id)
            .where(CompanyMember.subject == user.subject)
            .order_by(Company.name)
        )
        return [CompanyOut(**_fields(company), role=Role(role)) for company, role in rows]

    @router.post("/api/companies", status_code=status.HTTP_201_CREATED)
    def create_company(data: CompanyCreate, user: User, db: Db) -> CompanyDetails:
        company = Company(**data.model_dump(exclude={"display_name"}))
        db.add(company)
        db.flush()
        me = CompanyMember(
            company_id=company.id,
            subject=user.subject,
            display_name=_display_name(data.display_name, user),
            role=Role.OWNER,
        )
        db.add(me)
        db.commit()
        return details(db, company, me)

    @router.get("/api/companies/{company_id}")
    def get_company(company_id: str, user: User, db: Db) -> CompanyDetails:
        me = require_member(db, company_id, user)
        return details(db, db.get(Company, company_id), me)

    @router.put("/api/companies/{company_id}")
    def update_company(company_id: str, data: CompanyIn, user: User, db: Db) -> CompanyDetails:
        me = require_member(db, company_id, user, {Role.OWNER})
        company = db.get(Company, company_id)
        for field, value in data.model_dump().items():
            setattr(company, field, value)
        db.commit()
        return details(db, company, me)

    @router.delete("/api/companies/{company_id}", status_code=status.HTTP_204_NO_CONTENT)
    def delete_company(company_id: str, user: User, db: Db) -> Response:
        require_member(db, company_id, user, {Role.OWNER})
        # Pojazdy firmy nie znikają – wracają do tego, kto je dodał.
        vehicles = Base.metadata.tables["vehicle_profiles"]
        db.execute(
            update(vehicles).where(vehicles.c.company_id == company_id).values(company_id=None)
        )
        for model in (CompanyBase, CompanyInvite, CompanyMember):
            for row in db.scalars(select(model).where(model.company_id == company_id)):
                db.delete(row)
        db.delete(db.get(Company, company_id))
        db.commit()
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @router.get("/api/companies/{company_id}/invites")
    def list_invites(company_id: str, user: User, db: Db) -> list[InviteOut]:
        require_member(db, company_id, user, MANAGES_VEHICLES)
        invites = db.scalars(
            select(CompanyInvite)
            .where(CompanyInvite.company_id == company_id)
            .order_by(CompanyInvite.created_at)
        )
        return [InviteOut.model_validate(i) for i in invites if _aware(i.expires_at) > _now()]

    @router.post("/api/companies/{company_id}/invites", status_code=status.HTTP_201_CREATED)
    def create_invite(company_id: str, data: InviteIn, user: User, db: Db) -> InviteOut:
        me = require_member(db, company_id, user, MANAGES_VEHICLES)
        if me.role != Role.OWNER and data.role != Role.DRIVER:
            raise HTTPException(
                status.HTTP_403_FORBIDDEN, "Dyspozytor może zapraszać tylko kierowców."
            )
        code = _new_code()
        while db.get(CompanyInvite, code) is not None:
            code = _new_code()
        invite = CompanyInvite(
            code=code,
            company_id=company_id,
            role=data.role,
            note=data.note.strip(),
            created_by=user.subject,
            expires_at=_now() + timedelta(days=INVITE_VALID_DAYS),
        )
        db.add(invite)
        db.commit()
        return InviteOut.model_validate(invite)

    @router.delete(
        "/api/companies/{company_id}/invites/{code}", status_code=status.HTTP_204_NO_CONTENT
    )
    def cancel_invite(company_id: str, code: str, user: User, db: Db) -> Response:
        require_member(db, company_id, user, MANAGES_VEHICLES)
        invite = db.get(CompanyInvite, _normalize_code(code))
        if invite is None or invite.company_id != company_id:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Nie znaleziono zaproszenia.")
        db.delete(invite)
        db.commit()
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @router.post("/api/invites/{code}/accept")
    def accept_invite(code: str, data: JoinIn, user: User, db: Db) -> CompanyDetails:
        """Dołączenie do firmy kodem zaproszenia (kod jest jednorazowy)."""
        invite = db.get(CompanyInvite, _normalize_code(code))
        if invite is None or _aware(invite.expires_at) <= _now():
            raise HTTPException(
                status.HTTP_404_NOT_FOUND, "Kod zaproszenia jest nieprawidłowy albo wygasł."
            )
        company = db.get(Company, invite.company_id)
        if membership(db, company.id, user) is not None:
            raise HTTPException(status.HTTP_409_CONFLICT, "Już należysz do tej firmy.")
        me = CompanyMember(
            company_id=company.id,
            subject=user.subject,
            display_name=_display_name(data.display_name, user),
            role=invite.role,
        )
        db.add(me)
        db.delete(invite)
        db.commit()
        return details(db, company, me)

    @router.put("/api/companies/{company_id}/members/{member_id}")
    def change_role(
        company_id: str, member_id: str, data: RoleIn, user: User, db: Db
    ) -> CompanyDetails:
        me = require_member(db, company_id, user, {Role.OWNER})
        member = _member(db, company_id, member_id)
        if member.role == Role.OWNER and data.role != Role.OWNER and _owners(db, company_id) == 1:
            raise HTTPException(status.HTTP_409_CONFLICT, "Firma musi mieć właściciela.")
        member.role = data.role
        db.commit()
        return details(db, db.get(Company, company_id), me)

    @router.delete(
        "/api/companies/{company_id}/members/{member_id}", status_code=status.HTTP_204_NO_CONTENT
    )
    def remove_member(company_id: str, member_id: str, user: User, db: Db) -> Response:
        """Usunięcie członka (właściciel) albo opuszczenie firmy (każdy sam siebie)."""
        me = require_member(db, company_id, user)
        member = _member(db, company_id, member_id)
        if member.id != me.id and me.role != Role.OWNER:
            raise HTTPException(status.HTTP_403_FORBIDDEN, "Twoja rola w firmie na to nie pozwala.")
        if member.role == Role.OWNER and _owners(db, company_id) == 1:
            raise HTTPException(
                status.HTTP_409_CONFLICT,
                "Firma musi mieć właściciela: przekaż rolę komuś innemu albo usuń firmę.",
            )
        db.delete(member)
        db.commit()
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @router.get("/api/bases")
    def my_bases(user: User, db: Db) -> list[BaseOut]:
        """Bazy wszystkich firm użytkownika – do podpowiedzi w polach adresu."""
        rows = db.execute(
            select(CompanyBase, Company.name)
            .join(Company, Company.id == CompanyBase.company_id)
            .where(CompanyBase.company_id.in_(company_ids(db, user)))
            .order_by(Company.name, CompanyBase.name)
        )
        return [
            BaseOut.model_validate(base).model_copy(update={"company_name": name})
            for base, name in rows
        ]

    @router.post("/api/companies/{company_id}/bases", status_code=status.HTTP_201_CREATED)
    def add_base(company_id: str, data: BaseIn, user: User, db: Db) -> BaseOut:
        require_member(db, company_id, user, MANAGES_VEHICLES)
        base = CompanyBase(company_id=company_id, **data.model_dump())
        db.add(base)
        db.commit()
        return BaseOut.model_validate(base)

    @router.put("/api/companies/{company_id}/bases/{base_id}")
    def update_base(company_id: str, base_id: str, data: BaseIn, user: User, db: Db) -> BaseOut:
        require_member(db, company_id, user, MANAGES_VEHICLES)
        base = _base(db, company_id, base_id)
        for field, value in data.model_dump().items():
            setattr(base, field, value)
        db.commit()
        return BaseOut.model_validate(base)

    @router.delete(
        "/api/companies/{company_id}/bases/{base_id}", status_code=status.HTTP_204_NO_CONTENT
    )
    def delete_base(company_id: str, base_id: str, user: User, db: Db) -> Response:
        require_member(db, company_id, user, MANAGES_VEHICLES)
        db.delete(_base(db, company_id, base_id))
        db.commit()
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    return router


def _base(db: Session, company_id: str, base_id: str) -> CompanyBase:
    base = db.get(CompanyBase, base_id)
    if base is None or base.company_id != company_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Nie znaleziono bazy.")
    return base


def _fields(company: Company) -> dict:
    fields = CompanyIn.model_validate(company, from_attributes=True).model_dump()
    return {"id": company.id, **fields}


def _member(db: Session, company_id: str, member_id: str) -> CompanyMember:
    member = db.get(CompanyMember, member_id)
    if member is None or member.company_id != company_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Nie znaleziono członka firmy.")
    return member
