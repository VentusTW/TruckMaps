"""Aplikacja FastAPI rdzenia.

Uruchomienie: ``python -m truckmaps.core`` albo ``uvicorn truckmaps.core.app:create_app --factory``
"""

from collections.abc import AsyncIterator, Iterable
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.gzip import GZipMiddleware

from truckmaps.core import (
    admin,
    api,
    companies,
    corridor,
    currency,
    devlogin,
    geocoding,
    i18n,
    releases,
    reports,
    routing,
    vehicles,
)
from truckmaps.core.auth import AuthService, OidcProvider, TokenVerifier
from truckmaps.core.config import Settings
from truckmaps.core.db import Database
from truckmaps.core.defaults import register_defaults
from truckmaps.core.events import InProcessEventBus
from truckmaps.core.extensions import ExtensionRegistry
from truckmaps.core.licensing import StaticLicensing
from truckmaps.core.modules import ModuleManager
from truckmaps.core.version import CORE_VERSION
from truckmaps.sdk import CoreReady, Module


def create_app(
    settings: Settings | None = None,
    modules: Iterable[Module] | None = None,
    *,
    token_verifier: TokenVerifier | None = None,
    database: Database | None = None,
    router: routing.Router | None = None,
    geocoder: geocoding.Geocoder | None = None,
) -> FastAPI:
    """Tworzy aplikację.

    ``modules=None`` ładuje moduły zainstalowane (entry pointy); testy podają
    listę modułów, weryfikator tokenów, bazę i router tras wprost.
    """
    settings = settings or Settings.from_env()
    bus = InProcessEventBus()

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        updater = None
        if database is not None and settings.exchange_rates_url:
            updater = currency.RateUpdater(database, settings.exchange_rates_url)
            updater.start()
        bus.publish(CoreReady(modules=manager.active))
        yield
        if updater:
            updater.stop()

    app = FastAPI(title="TruckMaps", version=CORE_VERSION, lifespan=lifespan)
    # Trasy i korytarze danych to duże odpowiedzi JSON – kompresja zmniejsza je kilkukrotnie.
    app.add_middleware(GZipMiddleware, minimum_size=2000)
    # Język tekstów dla użytkownika z nagłówka Accept-Language (bez niego – polski).
    app.add_middleware(i18n.LanguageMiddleware)
    # Dziennik wywołań programu administracyjnego (kto, co, kiedy, skąd, z jakim wynikiem).
    app.add_middleware(admin.AuditMiddleware)

    provider = None
    if settings.oidc_enabled:
        provider = OidcProvider(
            settings.oidc_issuer,
            settings.oidc_client_id,
            project_id=settings.oidc_project_id,
        )
    auth = AuthService(token_verifier or provider)

    extensions = ExtensionRegistry()
    register_defaults(extensions)
    licensing = StaticLicensing(
        settings.licenses, optional_user=auth.optional_user, grant_all=settings.dev_grant_all
    )

    manager = ModuleManager(
        app=app,
        auth=auth,
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

    if database is None and settings.database_url:
        database = Database(settings.database_url)

    app.state.auth = auth
    app.state.database = database
    app.state.events = bus
    app.state.extensions = extensions
    app.state.modules = manager
    app.state.licensing = licensing
    app.state.router = router or routing.ValhallaRouter(settings.valhalla_url)
    app.state.geocoder = geocoder or geocoding.PhotonGeocoder(settings.photon_url)
    app.include_router(api.build_router(auth.current_user))
    app.include_router(companies.build_router(auth.current_user))
    app.include_router(vehicles.build_router(auth.current_user))
    app.include_router(routing.build_router(auth.current_user))
    app.include_router(corridor.build_router(auth.current_user))
    app.include_router(reports.build_router(auth.current_user))
    app.include_router(releases.build_router(auth.current_user))
    app.include_router(currency.build_router(auth.current_user))
    app.include_router(geocoding.build_router(auth.current_user))
    app.include_router(admin.build_router(auth.current_user, settings, licensing))
    if settings.dev_login_page and provider is not None:
        app.include_router(devlogin.build_router(provider, settings.public_url))
    return app
