"""Kafelki mapy wektorowej (PMTiles, schemat OpenMapTiles) z katalogu ``tiles_dir``.

Pliki generuje ``infra/build_tiles.ps1`` (Planetiler z danych OSM). Aplikacja czyta plik
fragmentami (nagłówek HTTP ``Range``), więc serwer oddaje go jak zwykły plik statyczny.
Mapa nie wymaga logowania – dane OSM (licencja ODbL) są publiczne.
"""

import re
from pathlib import Path

from fastapi import APIRouter, HTTPException, status
from fastapi.responses import FileResponse
from pydantic import BaseModel

from truckmaps.core.i18n import t

_NAME = re.compile(r"^[a-z0-9_-]{1,60}$")


class TileArchive(BaseModel):
    name: str
    url: str
    size_mb: float


def archives(tiles_dir: Path | None) -> list[TileArchive]:
    if tiles_dir is None or not tiles_dir.is_dir():
        return []
    return [
        TileArchive(
            name=path.stem,
            url=f"/api/tiles/{path.name}",
            size_mb=round(path.stat().st_size / 1e6, 1),
        )
        for path in sorted(tiles_dir.glob("*.pmtiles"))
        if _NAME.match(path.stem)
    ]


def build_router(tiles_dir: Path | None) -> APIRouter:
    router = APIRouter(prefix="/api/tiles", tags=["tiles"])

    @router.get("")
    def list_archives() -> list[TileArchive]:
        return archives(tiles_dir)

    @router.get("/{name}.pmtiles")
    def archive(name: str) -> FileResponse:
        path = tiles_dir / f"{name}.pmtiles" if tiles_dir and _NAME.match(name) else None
        if path is None or not path.is_file():
            raise HTTPException(status.HTTP_404_NOT_FOUND, t("error.tiles_not_found"))
        # Plik zmienia się tylko przy aktualizacji danych – przeglądarka może go trzymać dzień.
        return FileResponse(
            path,
            media_type="application/vnd.pmtiles",
            headers={"Cache-Control": "public, max-age=86400"},
        )

    return router
