"""Wpisy, pliki i ustawienia firmy – wspólne dla ekranów panelu.

- **Wpisy** (``EntityRecord``): dane bez osobnej tabeli przy kierowcy, pojeździe, zleceniu albo
  firmie – urlopy, kontakt awaryjny, delegacje, opony, gwarancje, certyfikaty, lista kontrolna
  zlecenia, części w magazynie i w zleceniu, zapotrzebowanie, premie, historia zmian. Rodzaj
  (``kind``) i treść (``data``, JSON) ustala ekran; serwer pilnuje firmy i uprawnień.
- **Pliki** (``EntityFile``): zdjęcia i skany dokumentów (do ``MAX_FILE_BYTES``) w bazie.
- **Ustawienia firmy**: wartości JSON pod kluczem (liczba stanowisk, cel MTTR, budżet,
  wybrane KPI, harmonogram raportu).
- **Raport cykliczny**: ustawienie ``report_schedule`` (``weekly`` / ``monthly``) – zadanie
  w tle wysyła właścicielowi i dyspozytorom podsumowanie przejazdów do skrzynki (i e-mailem,
  gdy jest skonfigurowany).
"""

import base64
import binascii
import uuid
from datetime import UTC, date, datetime, timedelta
from typing import Annotated, Any

from fastapi import APIRouter, Body, Depends, HTTPException, Path, Query, Response, status
from pydantic import BaseModel, Field
from sqlalchemy import JSON, DateTime, LargeBinary, String, func, select
from sqlalchemy.orm import Mapped, Session, mapped_column

from truckmaps.core import inbox
from truckmaps.core.companies import Company, CompanyMember, Role, membership, require_member
from truckmaps.core.db import Base, get_session
from truckmaps.core.i18n import t
from truckmaps.sdk import Principal

ENTITY_TYPES = ("driver", "vehicle", "order", "company")
MAX_FILE_BYTES = 5 * 1024 * 1024
WRITERS = {Role.OWNER, Role.DISPATCHER, Role.MECHANIC}
"""Zmieniać wpisy i pliki mogą biuro i mechanik; czytać – każdy członek firmy."""
SCHEDULES = {"weekly": 7, "monthly": 30}
REPORT_KIND = "report_scheduled"


def _now() -> datetime:
    return datetime.now(UTC)


def _id() -> str:
    return str(uuid.uuid4())


class EntityRecord(Base):
    __tablename__ = "entity_records"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_id)
    company_id: Mapped[str] = mapped_column(String(36), index=True)
    entity_type: Mapped[str] = mapped_column(String(20))
    entity_id: Mapped[str] = mapped_column(String(64), index=True)
    kind: Mapped[str] = mapped_column(String(40))
    data: Mapped[dict] = mapped_column(JSON, default=dict)
    created_by: Mapped[str] = mapped_column(String(255))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class EntityFile(Base):
    __tablename__ = "entity_files"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_id)
    company_id: Mapped[str] = mapped_column(String(36), index=True)
    entity_type: Mapped[str] = mapped_column(String(20))
    entity_id: Mapped[str] = mapped_column(String(64), index=True)
    kind: Mapped[str] = mapped_column(String(40))
    name: Mapped[str] = mapped_column(String(200))
    content_type: Mapped[str] = mapped_column(String(100))
    size: Mapped[int]
    content: Mapped[bytes] = mapped_column(LargeBinary)
    created_by: Mapped[str] = mapped_column(String(255))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class CompanySetting(Base):
    __tablename__ = "company_settings"

    company_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    key: Mapped[str] = mapped_column(String(60), primary_key=True)
    value: Mapped[Any] = mapped_column(JSON)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class RecordIn(BaseModel):
    entity_type: str = Field(pattern="^(driver|vehicle|order|company)$")
    entity_id: str = Field(min_length=1, max_length=64)
    kind: str = Field(pattern="^[a-z_]{1,40}$")
    data: dict = {}


class RecordUpdate(BaseModel):
    data: dict


class RecordOut(BaseModel):
    id: str
    entity_type: str
    entity_id: str
    kind: str
    data: dict
    created_at: datetime
    updated_at: datetime


class FileIn(BaseModel):
    entity_type: str = Field(pattern="^(driver|vehicle|order|company)$")
    entity_id: str = Field(min_length=1, max_length=64)
    kind: str = Field(default="document", pattern="^[a-z_]{1,40}$")
    name: str = Field(min_length=1, max_length=200)
    content_type: str = Field(default="application/octet-stream", max_length=100)
    data: str = Field(description="Treść pliku w base64")


class FileOut(BaseModel):
    id: str
    entity_type: str
    entity_id: str
    kind: str
    name: str
    content_type: str
    size: int
    created_at: datetime


def _record_out(r: EntityRecord) -> RecordOut:
    return RecordOut(
        id=r.id,
        entity_type=r.entity_type,
        entity_id=r.entity_id,
        kind=r.kind,
        data=r.data or {},
        created_at=r.created_at,
        updated_at=r.updated_at,
    )


def _file_out(f: EntityFile) -> FileOut:
    return FileOut(
        id=f.id,
        entity_type=f.entity_type,
        entity_id=f.entity_id,
        kind=f.kind,
        name=f.name,
        content_type=f.content_type,
        size=f.size,
        created_at=f.created_at,
    )


def get_setting(db: Session, company_id: str, key: str, default: Any = None) -> Any:
    row = db.get(CompanySetting, (company_id, key))
    return default if row is None else row.value


def trip_summary(db: Session, company_id: str, since: datetime) -> dict:
    """Przejazdy pojazdów firmy od ``since``: liczba, km, godziny postoju."""
    from truckmaps.core.trips import VehicleTrip  # bez cyklu importów przy starcie
    from truckmaps.core.vehicles import VehicleProfile

    row = db.execute(
        select(func.count(), func.coalesce(func.sum(VehicleTrip.distance_km), 0.0))
        .select_from(VehicleTrip)
        .join(VehicleProfile, VehicleProfile.id == VehicleTrip.vehicle_id)
        .where(VehicleProfile.company_id == company_id, VehicleTrip.started_at >= since)
    ).one()
    return {"trips": int(row[0]), "distance_km": round(float(row[1]), 1)}


def send_scheduled_reports(db: Session, today: date | None = None) -> int:
    """Raport cykliczny firm z ustawieniem ``report_schedule`` – do skrzynki biura."""
    day = today or _now().date()
    sent = 0
    for setting in db.scalars(
        select(CompanySetting).where(CompanySetting.key == "report_schedule")
    ):
        days = SCHEDULES.get(str(setting.value))
        if days is None:
            continue
        last = get_setting(db, setting.company_id, "report_last_sent")
        if last and date.fromisoformat(last) + timedelta(days=days) > day:
            continue
        since = datetime.combine(day - timedelta(days=days), datetime.min.time(), UTC)
        summary = trip_summary(db, setting.company_id, since)
        office = [
            m.subject
            for m in db.scalars(
                select(CompanyMember).where(CompanyMember.company_id == setting.company_id)
            )
            if m.role in (Role.OWNER, Role.DISPATCHER)
        ]
        company = db.get(Company, setting.company_id)
        inbox.send(
            db,
            office,
            REPORT_KIND,
            sender_name=company.name if company else "",
            company_id=setting.company_id,
            data={"period_days": days, "since": since.date().isoformat(), **summary},
        )
        _put_setting(db, setting.company_id, "report_last_sent", day.isoformat())
        sent += len(office)
    db.commit()
    return sent


def _put_setting(db: Session, company_id: str, key: str, value: Any) -> None:
    row = db.get(CompanySetting, (company_id, key)) or CompanySetting(
        company_id=company_id, key=key
    )
    row.value = value
    row.updated_at = _now()
    db.add(row)


def build_router(current_user) -> APIRouter:
    router = APIRouter(tags=["records"])
    User = Annotated[Principal, Depends(current_user)]
    Db = Annotated[Session, Depends(get_session)]

    def reader(db: Session, company_id: str, user: Principal) -> CompanyMember:
        member = membership(db, company_id, user)
        if member is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("error.company_not_found"))
        return member

    @router.get("/api/companies/{company_id}/records")
    def list_records(
        company_id: str,
        user: User,
        db: Db,
        entity_type: Annotated[str | None, Query()] = None,
        entity_id: Annotated[str | None, Query()] = None,
        kind: Annotated[str | None, Query()] = None,
    ) -> list[RecordOut]:
        reader(db, company_id, user)
        query = select(EntityRecord).where(EntityRecord.company_id == company_id)
        if entity_type:
            query = query.where(EntityRecord.entity_type == entity_type)
        if entity_id:
            query = query.where(EntityRecord.entity_id == entity_id)
        if kind:
            query = query.where(EntityRecord.kind == kind)
        return [
            _record_out(r)
            for r in db.scalars(query.order_by(EntityRecord.created_at.desc()).limit(1000))
        ]

    @router.post("/api/companies/{company_id}/records", status_code=201)
    def add_record(company_id: str, data: RecordIn, user: User, db: Db) -> RecordOut:
        require_member(db, company_id, user, WRITERS)
        record = EntityRecord(company_id=company_id, created_by=user.subject, **data.model_dump())
        db.add(record)
        db.commit()
        return _record_out(record)

    def own_record(db: Session, company_id: str, record_id: str) -> EntityRecord:
        record = db.get(EntityRecord, record_id)
        if record is None or record.company_id != company_id:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("records.not_found"))
        return record

    @router.put("/api/companies/{company_id}/records/{record_id}")
    def update_record(
        company_id: str, record_id: str, data: RecordUpdate, user: User, db: Db
    ) -> RecordOut:
        require_member(db, company_id, user, WRITERS)
        record = own_record(db, company_id, record_id)
        record.data = data.data
        record.updated_at = _now()
        db.commit()
        return _record_out(record)

    @router.delete("/api/companies/{company_id}/records/{record_id}", status_code=204)
    def delete_record(company_id: str, record_id: str, user: User, db: Db) -> Response:
        require_member(db, company_id, user, WRITERS)
        db.delete(own_record(db, company_id, record_id))
        db.commit()
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @router.get("/api/companies/{company_id}/files")
    def list_files(
        company_id: str,
        user: User,
        db: Db,
        entity_type: Annotated[str, Query()],
        entity_id: Annotated[str, Query()],
    ) -> list[FileOut]:
        reader(db, company_id, user)
        query = (
            select(EntityFile)
            .where(
                EntityFile.company_id == company_id,
                EntityFile.entity_type == entity_type,
                EntityFile.entity_id == entity_id,
            )
            .order_by(EntityFile.created_at.desc())
        )
        return [_file_out(f) for f in db.scalars(query)]

    @router.post("/api/companies/{company_id}/files", status_code=201)
    def add_file(company_id: str, data: FileIn, user: User, db: Db) -> FileOut:
        require_member(db, company_id, user, WRITERS)
        try:
            content = base64.b64decode(data.data.split(",")[-1], validate=True)
        except (binascii.Error, ValueError) as error:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_CONTENT, t("records.bad_file")
            ) from error
        if len(content) > MAX_FILE_BYTES:
            raise HTTPException(
                status.HTTP_413_CONTENT_TOO_LARGE, t("records.file_too_large", mb=5)
            )
        file = EntityFile(
            company_id=company_id,
            entity_type=data.entity_type,
            entity_id=data.entity_id,
            kind=data.kind,
            name=data.name,
            content_type=data.content_type,
            size=len(content),
            content=content,
            created_by=user.subject,
        )
        db.add(file)
        db.commit()
        return _file_out(file)

    @router.get("/api/companies/{company_id}/files/{file_id}")
    def get_file(company_id: str, file_id: str, user: User, db: Db) -> Response:
        reader(db, company_id, user)
        file = db.get(EntityFile, file_id)
        if file is None or file.company_id != company_id:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("records.not_found"))
        return Response(file.content, media_type=file.content_type)

    @router.delete("/api/companies/{company_id}/files/{file_id}", status_code=204)
    def delete_file(company_id: str, file_id: str, user: User, db: Db) -> Response:
        require_member(db, company_id, user, WRITERS)
        file = db.get(EntityFile, file_id)
        if file is None or file.company_id != company_id:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("records.not_found"))
        db.delete(file)
        db.commit()
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @router.get("/api/companies/{company_id}/settings")
    def company_settings(company_id: str, user: User, db: Db) -> dict[str, Any]:
        reader(db, company_id, user)
        return {
            s.key: s.value
            for s in db.scalars(
                select(CompanySetting).where(CompanySetting.company_id == company_id)
            )
        }

    @router.put("/api/companies/{company_id}/settings/{key}")
    def put_company_setting(
        company_id: str,
        key: Annotated[str, Path(pattern="^[a-z_]{1,60}$")],
        value: Annotated[Any, Body()],
        user: User,
        db: Db,
    ) -> dict[str, Any]:
        require_member(db, company_id, user, {Role.OWNER, Role.DISPATCHER, Role.MECHANIC})
        _put_setting(db, company_id, key, value)
        db.commit()
        return {key: value}

    @router.get("/api/fuel-prices")
    def fuel_price_list(user: User, db: Db) -> dict:
        """Ceny oleju napędowego (EUR/l) w krajach UE z ostatniego biuletynu KE."""
        from truckmaps.core import fuel_prices

        prices = fuel_prices.latest(db)
        return {"day": prices.day, "diesel_eur": prices.diesel_eur}

    @router.get("/api/companies/{company_id}/trip-summary")
    def company_trip_summary(
        company_id: str, user: User, db: Db, days: Annotated[int, Query(ge=1, le=366)] = 30
    ):
        reader(db, company_id, user)
        return trip_summary(db, company_id, _now() - timedelta(days=days))

    return router
