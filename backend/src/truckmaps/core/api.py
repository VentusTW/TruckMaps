from dataclasses import asdict

from fastapi import APIRouter, Request

from truckmaps.core.version import CORE_VERSION

router = APIRouter(prefix="/api", tags=["core"])


@router.get("/health")
def health() -> dict:
    return {"status": "ok", "core_version": CORE_VERSION}


@router.get("/modules")
def modules(request: Request) -> list[dict]:
    """Stan wszystkich wykrytych modułów – także wyłączonych i tych, które się nie załadowały."""
    return [asdict(status) for status in request.app.state.modules.statuses.values()]
