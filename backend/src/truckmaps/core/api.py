from dataclasses import asdict
from typing import Annotated

from fastapi import APIRouter, Depends, Request

from truckmaps.core.modules import ModuleState
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

    @router.get("/me/modules")
    def my_modules(
        request: Request, user: Annotated[Principal, Depends(current_user)]
    ) -> list[dict]:
        """Moduły działające na serwerze i czy to konto ma do nich dostęp.

        Aplikacja pokazuje moduł z dostępem, a pozostałe – z ekranem „Kup moduł”.
        """
        licensing = request.app.state.licensing
        return [
            {
                "id": status.id,
                "name": status.name or status.id,
                "version": status.version,
                "granted": licensing.is_granted(user, status.id),
            }
            for status in request.app.state.modules.statuses.values()
            if status.state == ModuleState.ACTIVE
        ]

    return router
