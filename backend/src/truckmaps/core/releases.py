"""Wydania aplikacji, modułów i pakietów danych: sprawdzanie wersji i stopniowe wydania.

Aplikacja po zalogowaniu podaje, co ma zainstalowane, a serwer odpowiada, co jest nowsze.
Nowe wydanie trafia najpierw do części użytkowników (``rollout`` w procentach, ten sam
użytkownik zawsze w tej samej części). Wstrzymane wydanie nie trafia do nikogo nowego;
wycofane – dodatkowo wskazuje tym, którzy już je mają, poprzednie aktywne wydanie.

Wydaniami zarządza polecenie ``python -m truckmaps.core.releases`` (zob. ``main``).
"""

import argparse
import hashlib
import re
import uuid
from datetime import UTC, datetime
from enum import StrEnum
from pathlib import Path
from typing import Annotated, Literal

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from sqlalchemy import JSON, DateTime, String, UniqueConstraint, select
from sqlalchemy.orm import Mapped, Session, mapped_column

from truckmaps.core.config import Settings, load_env_file
from truckmaps.core.db import Base, Database, get_session
from truckmaps.core.i18n import language, t
from truckmaps.sdk import Principal
from truckmaps.sdk.i18n import DEFAULT_LANGUAGE

APP = "truckmaps"
"""Nazwa aplikacji w katalogu wydań (``kind=app``)."""


class Kind(StrEnum):
    APP = "app"
    MODULE = "module"
    DATA = "data"
    """Pakiety danych: mapy offline, korytarz, baza ograniczeń."""


class Status(StrEnum):
    ACTIVE = "active"
    PAUSED = "paused"
    """Nie trafia do nowych użytkowników; kto już ma, zostaje przy nim."""
    WITHDRAWN = "withdrawn"
    """Wycofane: kto już ma, dostaje propozycję powrotu do poprzedniego wydania."""


Platform = Literal["android", "ios", "windows", "macos", "linux", "web"]


def _now() -> datetime:
    return datetime.now(UTC)


class Release(Base):
    __tablename__ = "releases"
    __table_args__ = (UniqueConstraint("kind", "name", "platform", "version"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    kind: Mapped[str] = mapped_column(String(10))
    name: Mapped[str] = mapped_column(String(64))
    platform: Mapped[str] = mapped_column(String(10), default="")
    """Pusty = każda platforma (moduły, dane)."""
    version: Mapped[str] = mapped_column(String(30))
    url: Mapped[str] = mapped_column(String(500))
    size_bytes: Mapped[int]
    sha256: Mapped[str] = mapped_column(String(64), default="")
    notes: Mapped[dict] = mapped_column(JSON, default=dict)
    """Lista zmian w językach: ``{"pl": "...", "en": "..."}``."""
    rollout: Mapped[int] = mapped_column(default=100)
    """Procent użytkowników, którzy dostają wydanie."""
    status: Mapped[str] = mapped_column(String(10), default=Status.ACTIVE)
    published_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


def version_key(version: str) -> tuple[int, ...]:
    """``"1.10.2+5"`` → ``(1, 10, 2)``: porównanie liczb, nie tekstu; numer kompilacji pomijamy."""
    return tuple(int(part) for part in re.findall(r"\d+", version.split("+")[0])[:4])


def in_rollout(release: Release, subject: str) -> bool:
    """Ten sam użytkownik zawsze w tej samej części; każde wydanie losuje osobno."""
    if release.rollout >= 100:
        return True
    digest = hashlib.sha256(f"{release.id}:{subject}".encode()).digest()
    return int.from_bytes(digest[:4], "big") % 100 < release.rollout


def _notes(release: Release) -> str:
    notes = release.notes or {}
    return notes.get(language()) or notes.get(DEFAULT_LANGUAGE) or next(iter(notes.values()), "")


class Installed(BaseModel):
    kind: Kind
    name: str = Field(max_length=64, examples=[APP])
    version: str = Field(max_length=30, examples=["0.1.0"])


class UpdateCheck(BaseModel):
    platform: Platform
    installed: list[Installed] = Field(max_length=100)


class UpdateOut(BaseModel):
    kind: Kind
    name: str
    installed_version: str
    version: str
    action: Literal["update", "rollback"]
    """``rollback`` – zainstalowane wydanie wycofano, ``version`` to poprzednie dobre."""
    url: str
    size_bytes: int
    sha256: str
    notes: str
    """Lista zmian w języku zapytania."""
    published_at: datetime


def check(db: Session, data: UpdateCheck, subject: str) -> list[UpdateOut]:
    updates = []
    for item in data.installed:
        releases = db.scalars(
            select(Release).where(
                Release.kind == item.kind,
                Release.name == item.name,
                Release.platform.in_(("", data.platform)),
            )
        ).all()
        releases.sort(key=lambda r: version_key(r.version), reverse=True)
        installed = version_key(item.version)
        mine = next((r for r in releases if version_key(r.version) == installed), None)
        good = [r for r in releases if r.status == Status.ACTIVE and in_rollout(r, subject)]
        if mine is not None and mine.status == Status.WITHDRAWN:
            target = next((r for r in good if version_key(r.version) != installed), None)
            action = "update" if target and version_key(target.version) > installed else "rollback"
        else:
            target = next((r for r in good if version_key(r.version) > installed), None)
            action = "update"
        if target is not None:
            updates.append(
                UpdateOut(
                    kind=item.kind,
                    name=item.name,
                    installed_version=item.version,
                    version=target.version,
                    action=action,
                    url=target.url,
                    size_bytes=target.size_bytes,
                    sha256=target.sha256,
                    notes=_notes(target),
                    published_at=target.published_at,
                )
            )
    return updates


def build_router(current_user) -> APIRouter:
    router = APIRouter(tags=["updates"])
    User = Annotated[Principal, Depends(current_user)]
    Db = Annotated[Session, Depends(get_session)]

    @router.post("/api/updates/check")
    def check_updates(data: UpdateCheck, user: User, db: Db) -> list[UpdateOut]:
        """Nowsze wydania tego, co ma zainstalowane aplikacja (albo powrót z wycofanego)."""
        return check(db, data, user.subject)

    return router


def _find(db: Session, args: argparse.Namespace) -> Release:
    release = db.scalar(
        select(Release).where(
            Release.kind == args.kind,
            Release.name == args.name,
            Release.platform == args.platform,
            Release.version == args.version,
        )
    )
    if release is None:
        raise SystemExit(t("releases.not_found", version=args.version))
    return release


def main(argv: list[str] | None = None, database: Database | None = None) -> None:
    """Zarządzanie wydaniami: dodanie, stopniowe wydanie, wstrzymanie, wycofanie, lista."""
    parser = argparse.ArgumentParser(prog="python -m truckmaps.core.releases")
    commands = parser.add_subparsers(dest="command", required=True)

    def target(command: argparse.ArgumentParser, version: bool = True) -> None:
        command.add_argument("--kind", choices=list(Kind), default=Kind.APP)
        command.add_argument("--name", default=APP)
        command.add_argument("--platform", default="", help="android, windows, …; puste = każda")
        if version:
            command.add_argument("version")

    add = commands.add_parser("add", help="nowe wydanie")
    target(add)
    add.add_argument("--url", required=True)
    add.add_argument("--size", type=int, required=True, help="rozmiar w bajtach")
    add.add_argument("--sha256", default="")
    add.add_argument("--notes", action="append", default=[], metavar="JĘZYK=TEKST")
    add.add_argument("--rollout", type=int, default=100, choices=range(0, 101), metavar="0-100")
    rollout = commands.add_parser("rollout", help="zmiana procentu użytkowników")
    target(rollout)
    rollout.add_argument("percent", type=int, choices=range(0, 101), metavar="0-100")
    for name in ("pause", "resume", "withdraw"):
        target(commands.add_parser(name))
    target(commands.add_parser("list"), version=False)
    args = parser.parse_args(argv)

    if database is None:
        load_env_file(Path.cwd() / ".env")
        url = Settings.from_env().database_url
        if not url:
            raise SystemExit(t("error.database_not_configured"))
        database = Database(url)
    with database.session() as db:
        if args.command == "add":
            notes = dict(note.split("=", 1) for note in args.notes if "=" in note)
            db.add(
                Release(
                    kind=args.kind,
                    name=args.name,
                    platform=args.platform,
                    version=args.version,
                    url=args.url,
                    size_bytes=args.size,
                    sha256=args.sha256,
                    notes=notes,
                    rollout=args.rollout,
                )
            )
        elif args.command == "list":
            rows = db.scalars(
                select(Release).where(Release.kind == args.kind, Release.name == args.name)
            ).all()
            for r in sorted(rows, key=lambda r: version_key(r.version), reverse=True):
                platform = r.platform or "*"
                print(f"{r.version:<12} {platform:<8} {r.status:<10} {r.rollout:>3}%  {r.url}")
            return
        else:
            release = _find(db, args)
            if args.command == "rollout":
                release.rollout = args.percent
            else:
                release.status = {
                    "pause": Status.PAUSED,
                    "resume": Status.ACTIVE,
                    "withdraw": Status.WITHDRAWN,
                }[args.command]
        db.commit()
        print(t("releases.saved", version=args.version))


if __name__ == "__main__":
    main()
