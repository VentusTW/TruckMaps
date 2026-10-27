from dataclasses import asdict
from typing import Annotated

from fastapi import APIRouter, Depends, Request

from truckmaps.core.version import CORE_VERSION
from truckmaps.sdk import Principal


def build_router(current_user) -> APIRouter:
    router = APIRouter(prefix="/api", tags=["core"])

    @router.get("/health")
    def health() -> dict:
        return {"status": "ok", "core_version": CORE_VERSION}

    @router.get("/modules")
    def modules(request: Request) -> list[dict]:
        """Stan wykrytych modułów – także wyłączonych i tych, które się nie załadowały."""
        return [asdict(status) for status in request.app.state.modules.statuses.values()]

    @router.get("/me")
    def me(user: Annotated[Principal, Depends(current_user)]) -> dict:
        """Zalogowany użytkownik."""
        return {"subject": user.subject, "organization_id": user.organization_id}

    return router
