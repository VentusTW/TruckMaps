"""Trasy od dyspozytora: centrala planuje trasę pojazdu firmy (z dowolnym startem – pojazd może
być teraz gdzie indziej) i wysyła ją kierowcy. Kierowca dostaje wiadomość w skrzynce, otwiera
trasę w aplikacji i rusza od startu albo od swojej pozycji z dojazdem do startu.
"""

import uuid
from datetime import UTC, datetime
from enum import StrEnum
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Response, status
from pydantic import BaseModel, Field
from sqlalchemy import JSON, DateTime, Float, String, select
from sqlalchemy.orm import Mapped, Session, mapped_column

from truckmaps.core import inbox
from truckmaps.core.companies import CompanyMember, Role, membership, require_member
from truckmaps.core.db import Base, get_session
from truckmaps.core.i18n import t
from truckmaps.core.vehicles import VehicleProfile
from truckmaps.sdk import Principal

PLANNERS = {Role.OWNER, Role.DISPATCHER}
ROUTE_ASSIGNED = "route_assigned"
"""Rodzaj wiadomości w skrzynce kierowcy (dane: ``assignment_id`` i opis trasy)."""


class AssignmentState(StrEnum):
    SENT = "sent"
    ACCEPTED = "accepted"
    """Kierowca otworzył trasę / ruszył."""
    DONE = "done"
    REJECTED = "rejected"


def _now() -> datetime:
    return datetime.now(UTC)


class RouteAssignment(Base):
    __tablename__ = "route_assignments"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    company_id: Mapped[str] = mapped_column(String(36), index=True)
    vehicle_id: Mapped[str] = mapped_column(String(36))
    driver_subject: Mapped[str] = mapped_column(String(255), index=True)
    created_by: Mapped[str] = mapped_column(String(255))
    stops: Mapped[list] = mapped_column(JSON)
    """Start, punkty pośrednie i cel: ``[{lat, lon, label}]`` po kolei."""
    avoid_difficult: Mapped[bool] = mapped_column(default=True)
    note: Mapped[str] = mapped_column(String(500), default="")
    distance_km: Mapped[float | None] = mapped_column(Float)
    duration_min: Mapped[float | None] = mapped_column(Float)
    state: Mapped[str] = mapped_column(String(20), default=AssignmentState.SENT)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class StopIn(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)
    label: str = Field(default="", max_length=200)


class AssignmentIn(BaseModel):
    vehicle_id: str
    driver_member_id: str = Field(description="Członek firmy (kierowca), który dostanie trasę")
    origin: StopIn = Field(description="Start trasy – nie musi być bieżącą pozycją pojazdu")
    destination: StopIn
    via: list[StopIn] = Field(default=[], max_length=20)
    avoid_difficult: bool = True
    note: str = Field(default="", max_length=500)
    distance_km: float | None = Field(default=None, ge=0)
    duration_min: float | None = Field(default=None, ge=0)


class AssignmentOut(BaseModel):
    id: str
    company_id: str
    vehicle_id: str
    vehicle_name: str
    plate: str | None
    driver_name: str
    origin: StopIn
    destination: StopIn
    via: list[StopIn]
    avoid_difficult: bool
    note: str
    distance_km: float | None
    duration_min: float | None
    state: AssignmentState
    created_at: datetime
    updated_at: datetime


class NoteIn(BaseModel):
    text: str = Field(min_length=1, max_length=1000)


class StateIn(BaseModel):
    state: AssignmentState


def _out(db: Session, a: RouteAssignment) -> AssignmentOut:
    vehicle = db.get(VehicleProfile, a.vehicle_id)
    driver = db.scalar(
        select(CompanyMember).where(
            CompanyMember.company_id == a.company_id, CompanyMember.subject == a.driver_subject
        )
    )
    stops = [StopIn(**s) for s in a.stops]
    return AssignmentOut(
        id=a.id,
        company_id=a.company_id,
        vehicle_id=a.vehicle_id,
        vehicle_name=vehicle.name if vehicle else "",
        plate=vehicle.plate if vehicle else None,
        driver_name=driver.display_name if driver else "",
        origin=stops[0],
        destination=stops[-1],
        via=stops[1:-1],
        avoid_difficult=a.avoid_difficult,
        note=a.note,
        distance_km=a.distance_km,
        duration_min=a.duration_min,
        state=AssignmentState(a.state),
        created_at=a.created_at,
        updated_at=a.updated_at,
    )


def build_router(current_user) -> APIRouter:
    router = APIRouter(tags=["dispatch"])
    User = Annotated[Principal, Depends(current_user)]
    Db = Annotated[Session, Depends(get_session)]

    def visible(db: Session, assignment_id: str, user: Principal) -> RouteAssignment:
        """Trasa widoczna dla kierowcy, który ją dostał, i dla planujących w firmie."""
        a = db.get(RouteAssignment, assignment_id)
        member = membership(db, a.company_id, user) if a else None
        if a is None or member is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("dispatch.not_found"))
        if a.driver_subject != user.subject and Role(member.role) not in PLANNERS:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("dispatch.not_found"))
        return a

    @router.post("/api/companies/{company_id}/route-assignments", status_code=201)
    def assign(company_id: str, data: AssignmentIn, user: User, db: Db) -> AssignmentOut:
        planner = require_member(db, company_id, user, PLANNERS)
        vehicle = db.get(VehicleProfile, data.vehicle_id)
        if vehicle is None or vehicle.company_id != company_id:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("error.vehicle_not_found"))
        driver = db.get(CompanyMember, data.driver_member_id)
        if driver is None or driver.company_id != company_id:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("dispatch.driver_not_found"))
        stops = [data.origin, *data.via, data.destination]
        a = RouteAssignment(
            company_id=company_id,
            vehicle_id=vehicle.id,
            driver_subject=driver.subject,
            created_by=user.subject,
            stops=[s.model_dump() for s in stops],
            avoid_difficult=data.avoid_difficult,
            note=data.note,
            distance_km=data.distance_km,
            duration_min=data.duration_min,
        )
        db.add(a)
        db.flush()
        inbox.send(
            db,
            [driver.subject],
            ROUTE_ASSIGNED,
            sender_name=planner.display_name,
            company_id=company_id,
            data={
                "assignment_id": a.id,
                "from": data.origin.label,
                "to": data.destination.label,
                "vehicle_name": vehicle.name,
                "plate": vehicle.plate,
                "note": data.note,
                "distance_km": data.distance_km,
                "duration_min": data.duration_min,
            },
        )
        db.commit()
        return _out(db, a)

    @router.post(
        "/api/companies/{company_id}/members/{member_id}/message",
        status_code=status.HTTP_204_NO_CONTENT,
    )
    def message_member(
        company_id: str, member_id: str, data: NoteIn, user: User, db: Db
    ) -> Response:
        """Wiadomość do kabiny: tekst od dyspozytora w skrzynce kierowcy."""
        sender = require_member(db, company_id, user, PLANNERS)
        member = db.get(CompanyMember, member_id)
        if member is None or member.company_id != company_id:
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("dispatch.driver_not_found"))
        inbox.send(
            db,
            [member.subject],
            inbox.Kind.DISPATCH_NOTE,
            sender_name=sender.display_name,
            company_id=company_id,
            data={"text": data.text.strip()},
        )
        db.commit()
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    @router.get("/api/companies/{company_id}/route-assignments")
    def company_assignments(company_id: str, user: User, db: Db) -> list[AssignmentOut]:
        """Ostatnie trasy wysłane kierowcom (centrala)."""
        require_member(db, company_id, user, PLANNERS)
        query = (
            select(RouteAssignment)
            .where(RouteAssignment.company_id == company_id)
            .order_by(RouteAssignment.created_at.desc())
            .limit(50)
        )
        return [_out(db, a) for a in db.scalars(query)]

    @router.get("/api/me/route-assignments")
    def my_assignments(user: User, db: Db) -> list[AssignmentOut]:
        """Trasy od dyspozytora dla zalogowanego kierowcy (jeszcze niezakończone)."""
        query = (
            select(RouteAssignment)
            .where(
                RouteAssignment.driver_subject == user.subject,
                RouteAssignment.state.in_((AssignmentState.SENT, AssignmentState.ACCEPTED)),
            )
            .order_by(RouteAssignment.created_at.desc())
        )
        return [_out(db, a) for a in db.scalars(query)]

    @router.get("/api/route-assignments/{assignment_id}")
    def get_assignment(assignment_id: str, user: User, db: Db) -> AssignmentOut:
        return _out(db, visible(db, assignment_id, user))

    @router.post("/api/route-assignments/{assignment_id}/state")
    def set_state(assignment_id: str, data: StateIn, user: User, db: Db) -> AssignmentOut:
        a = visible(db, assignment_id, user)
        a.state = data.state
        a.updated_at = _now()
        db.commit()
        return _out(db, a)

    return router
