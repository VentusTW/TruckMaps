"""Wykrywanie, sprawdzanie i rejestrowanie modułów."""

import logging
import re
from collections.abc import Callable
from dataclasses import dataclass, field
from enum import StrEnum
from importlib.metadata import EntryPoint, entry_points

from fastapi import APIRouter, Depends, FastAPI
from packaging.specifiers import InvalidSpecifier, SpecifierSet
from packaging.version import Version

from truckmaps.core.auth import AuthService
from truckmaps.core.events import InProcessEventBus
from truckmaps.core.extensions import ExtensionRegistry, check_implementation
from truckmaps.core.licensing import StaticLicensing
from truckmaps.core.version import CORE_VERSION
from truckmaps.sdk import Event, ExtensionPoint, Module

ENTRY_POINT_GROUP = "truckmaps.modules"
MODULE_ID_PATTERN = re.compile(r"^[a-z][a-z0-9_]{1,31}$")

log = logging.getLogger(__name__)


class ModuleState(StrEnum):
    ACTIVE = "active"
    DISABLED = "disabled"
    INCOMPATIBLE = "incompatible"
    FAILED = "failed"


@dataclass(frozen=True)
class ModuleStatus:
    id: str
    state: ModuleState
    name: str | None = None
    version: str | None = None
    error: str | None = None


class _ModuleApi:
    def __init__(self) -> None:
        self.routers: list[APIRouter] = []

    def include_router(self, router: APIRouter) -> None:
        self.routers.append(router)


class _ModuleEvents:
    def __init__(self, bus: InProcessEventBus) -> None:
        self._bus = bus
        self.subscriptions: list[tuple[type[Event], Callable]] = []

    def publish(self, event: Event) -> None:
        self._bus.publish(event)

    def subscribe[E: Event](self, event_type: type[E], handler: Callable[[E], None]) -> None:
        self.subscriptions.append((event_type, handler))


class _ModuleExtensions:
    def __init__(self, registry: ExtensionRegistry) -> None:
        self._registry = registry
        self.provided: list[tuple[ExtensionPoint, object, int]] = []

    def provide[T](self, point: ExtensionPoint[T], implementation: T, *, priority: int = 0) -> None:
        check_implementation(point, implementation)
        self.provided.append((point, implementation, priority))

    def get[T](self, point: ExtensionPoint[T]) -> T:
        return self._registry.get(point)


@dataclass
class ModuleContext:
    """``CoreContext`` jednego modułu.

    Rejestracje są buforowane i włączane dopiero, gdy ``register`` zakończy się
    sukcesem – moduł, który się wywróci, nie zostawia po sobie połowy routerów.
    """

    module_id: str
    core_version: str
    api: _ModuleApi
    auth: AuthService
    events: _ModuleEvents
    extensions: _ModuleExtensions
    logger: logging.Logger = field(repr=False)


class ModuleManager:
    def __init__(
        self,
        *,
        app: FastAPI,
        auth: AuthService,
        bus: InProcessEventBus,
        extensions: ExtensionRegistry,
        licensing: StaticLicensing,
        enabled: frozenset[str] | None = None,
    ) -> None:
        self._app = app
        self._auth = auth
        self._bus = bus
        self._extensions = extensions
        self._licensing = licensing
        self._enabled = enabled
        self.statuses: dict[str, ModuleStatus] = {}

    @property
    def active(self) -> tuple[str, ...]:
        return tuple(s.id for s in self.statuses.values() if s.state is ModuleState.ACTIVE)

    def load_installed(self) -> None:
        """Ładuje moduły zgłoszone przez entry pointy, w kolejności alfabetycznej."""
        for ep in sorted(entry_points(group=ENTRY_POINT_GROUP), key=lambda e: e.name):
            module = self._instantiate(ep)
            if module is not None:
                self.load(module)

    def load(self, module: Module) -> ModuleStatus:
        module_id = getattr(module, "id", None)
        if not isinstance(module_id, str) or not MODULE_ID_PATTERN.match(module_id):
            return self._fail(str(module_id), f"Nieprawidłowy identyfikator modułu: {module_id!r}")
        if module_id in self.statuses:
            # Nie nadpisujemy statusu pierwszego modułu o tym id.
            log.error("Moduł '%s' zgłoszony ponownie – pominięty", module_id)
            return ModuleStatus(module_id, ModuleState.FAILED, error="Zduplikowany identyfikator")

        name, version = getattr(module, "name", None), getattr(module, "version", None)
        if self._enabled is not None and module_id not in self._enabled:
            return self._record(ModuleStatus(module_id, ModuleState.DISABLED, name, version))

        try:
            compatible = Version(CORE_VERSION) in SpecifierSet(module.requires_core)
        except (AttributeError, InvalidSpecifier) as exc:
            return self._fail(module_id, f"Nieprawidłowe requires_core: {exc}", name, version)
        if not compatible:
            error = f"Wymaga rdzenia {module.requires_core}, jest {CORE_VERSION}"
            log.warning("Moduł '%s' pominięty: %s", module_id, error)
            return self._record(
                ModuleStatus(module_id, ModuleState.INCOMPATIBLE, name, version, error)
            )

        ctx = ModuleContext(
            module_id=module_id,
            core_version=CORE_VERSION,
            api=_ModuleApi(),
            auth=self._auth,
            events=_ModuleEvents(self._bus),
            extensions=_ModuleExtensions(self._extensions),
            logger=logging.getLogger(f"truckmaps.module.{module_id}"),
        )
        try:
            module.register(ctx)
        except Exception as exc:
            log.exception("Rejestracja modułu '%s' nie powiodła się", module_id)
            return self._fail(module_id, f"{type(exc).__name__}: {exc}", name, version)

        self._commit(module_id, ctx)
        log.info("Moduł '%s' %s aktywny", module_id, version)
        return self._record(ModuleStatus(module_id, ModuleState.ACTIVE, name, version))

    def _commit(self, module_id: str, ctx: ModuleContext) -> None:
        license_check = Depends(self._licensing.dependency(module_id))
        for router in ctx.api.routers:
            self._app.include_router(
                router, prefix=f"/api/m/{module_id}", tags=[module_id], dependencies=[license_check]
            )
        for event_type, handler in ctx.events.subscriptions:
            self._bus.subscribe(event_type, handler, owner=module_id)
        for point, implementation, priority in ctx.extensions.provided:
            self._extensions.provide(point, implementation, priority=priority, owner=module_id)

    def _instantiate(self, ep: EntryPoint) -> Module | None:
        try:
            module = ep.load()()
        except Exception as exc:
            log.exception("Nie udało się wczytać modułu '%s'", ep.name)
            self._fail(ep.name, f"{type(exc).__name__}: {exc}")
            return None
        if not isinstance(module, Module):
            self._fail(ep.name, f"{ep.value} nie dziedziczy po truckmaps.sdk.Module")
            return None
        if module.id != ep.name:
            self._fail(ep.name, f"Entry point '{ep.name}' wskazuje moduł o id '{module.id}'")
            return None
        return module

    def _fail(
        self, module_id: str, error: str, name: str | None = None, version: str | None = None
    ) -> ModuleStatus:
        return self._record(ModuleStatus(module_id, ModuleState.FAILED, name, version, error))

    def _record(self, status: ModuleStatus) -> ModuleStatus:
        self.statuses[status.id] = status
        return status
