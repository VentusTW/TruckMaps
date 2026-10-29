from typing import Annotated

from fastapi import APIRouter, Depends

from truckmaps.sdk import COST_PROVIDER, CoreContext, CoreReady, CostProfile, Module, Principal


class HelloModule(Module):
    """Pokazuje wszystko, czego moduł potrzebuje: router, zdarzenie i gniazdo rozszerzeń."""

    id = "hello"
    name = "Hello (moduł testowy)"
    version = "0.1.0"
    requires_core = ">=0.1,<1.0"

    def __init__(self) -> None:
        self.active_modules: tuple[str, ...] = ()

    def register(self, ctx: CoreContext) -> None:
        router = APIRouter()

        @router.get("/greeting")
        def greeting() -> dict:
            return {
                "message": "Witaj w TruckMaps!",
                "core_version": ctx.core_version,
                "active_modules": self.active_modules,
            }

        @router.get("/cost")
        def cost(distance_km: float, duration_h: float = 0.0) -> dict:
            provider = ctx.extensions.get(COST_PROVIDER)
            profile = CostProfile()
            amount = provider.estimate(distance_km, duration_h, profile)
            return {"amount": amount, "currency": profile.currency}

        @router.get("/whoami")
        def whoami(user: Annotated[Principal, Depends(ctx.auth.current_user)]) -> dict:
            return {"subject": user.subject}

        ctx.api.include_router(router)
        ctx.events.subscribe(CoreReady, self._on_core_ready)

    def _on_core_ready(self, event: CoreReady) -> None:
        self.active_modules = event.modules
