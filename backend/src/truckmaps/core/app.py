"""Aplikacja FastAPI rdzenia.

Uruchomienie: ``uvicorn truckmaps.core.app:create_app --factory``
"""

from collections.abc import AsyncIterator, Iterable
from contextlib import asynccontextmanager

from fastapi import FastAPI

from truckmaps.core import api
from truckmaps.core.config import Settings
from truckmaps.core.defaults import register_defaults
from truckmaps.core.events import InProcessEventBus
from truckmaps.core.extensions import ExtensionRegistry
from truckmaps.core.licensing import StaticLicensing
from truckmaps.core.modules import ModuleManager
from truckmaps.core.version import CORE_VERSION
from truckmaps.sdk import CoreReady, Module


def create_app(
    settings: Settings | None = None, modules: Iterable[Module] | None = None
) -> FastAPI:
    """Tworzy aplikację.

    ``modules=None`` ładuje moduły zainstalowane (entry pointy); testy podają
    listę modułów wprost.
    """
    settings = settings or Settings.from_env()
    bus = InProcessEventBus()

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        bus.publish(CoreReady(modules=manager.active))
        yield

    app = FastAPI(title="TruckMaps", version=CORE_VERSION, lifespan=lifespan)

    extensions = ExtensionRegistry()
    register_defaults(extensions)
    licensing = StaticLicensing(settings.licenses, grant_all=settings.dev_grant_all)

    manager = ModuleManager(
        app=app,
        bus=bus,
        extensions=extensions,
        licensing=licensing,
        enabled=settings.enabled_modules,
    )
    if modules is None:
        manager.load_installed()
    else:
        for module in modules:
            manager.load(module)

    app.state.events = bus
    app.state.extensions = extensions
    app.state.modules = manager
    app.include_router(api.router)
    return app
