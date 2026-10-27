from fastapi import APIRouter
from fastapi.testclient import TestClient

from truckmaps.core.app import create_app
from truckmaps.core.config import Settings
from truckmaps.core.modules import ModuleState
from truckmaps.sdk import COST_PROVIDER, CoreContext, CoreReady, CostProfile, Module


def make_module(module_id: str, *, requires_core: str = ">=0.1", on_register=None) -> Module:
    class _TestModule(Module):
        id = module_id
        name = f"Test {module_id}"
        version = "1.0.0"

        def __init__(self) -> None:
            self.events: list[CoreReady] = []

        def register(self, ctx: CoreContext) -> None:
            router = APIRouter()

            @router.get("/ping")
            def ping() -> dict:
                return {"module": ctx.module_id}

            ctx.api.include_router(router)
            ctx.events.subscribe(CoreReady, self.events.append)
            if on_register:
                on_register(ctx)

    _TestModule.requires_core = requires_core
    return _TestModule()


class DoubleCost:
    def estimate(self, distance_km: float, duration_h: float, profile: CostProfile) -> float:
        return 2 * distance_km


class TripleCost:
    def estimate(self, distance_km: float, duration_h: float, profile: CostProfile) -> float:
        return 3 * distance_km


def statuses(app) -> dict[str, ModuleState]:
    return {s.id: s.state for s in app.state.modules.statuses.values()}


def test_active_module_is_mounted_under_its_prefix():
    app = create_app(Settings(dev_grant_all=True), modules=[make_module("alpha")])

    with TestClient(app) as client:
        assert client.get("/api/m/alpha/ping").json() == {"module": "alpha"}


def test_disabled_module_is_not_mounted():
    settings = Settings(enabled_modules=frozenset({"alpha"}), dev_grant_all=True)
    app = create_app(settings, modules=[make_module("alpha"), make_module("beta")])

    with TestClient(app) as client:
        assert client.get("/api/m/beta/ping").status_code == 404
    assert statuses(app) == {"alpha": ModuleState.ACTIVE, "beta": ModuleState.DISABLED}


def test_incompatible_module_is_skipped():
    app = create_app(Settings(), modules=[make_module("alpha", requires_core=">=99")])

    assert statuses(app) == {"alpha": ModuleState.INCOMPATIBLE}


def test_failing_registration_is_rolled_back_and_others_keep_working():
    def explode(ctx: CoreContext) -> None:
        ctx.extensions.provide(COST_PROVIDER, DoubleCost())
        raise RuntimeError("boom")

    broken = make_module("broken", on_register=explode)
    healthy = make_module("healthy")
    app = create_app(Settings(dev_grant_all=True), modules=[broken, healthy])

    with TestClient(app) as client:
        assert client.get("/api/m/broken/ping").status_code == 404
        assert client.get("/api/m/healthy/ping").status_code == 200

    assert statuses(app) == {"broken": ModuleState.FAILED, "healthy": ModuleState.ACTIVE}
    assert broken.events == []
    assert app.state.extensions.owner(COST_PROVIDER) == "core"


def test_invalid_and_duplicate_ids_are_rejected():
    first = make_module("alpha")
    app = create_app(Settings(), modules=[make_module("Bad-Id"), first, make_module("alpha")])

    assert statuses(app) == {"Bad-Id": ModuleState.FAILED, "alpha": ModuleState.ACTIVE}


def test_failing_event_handler_does_not_block_other_modules():
    def subscribe_failing(ctx: CoreContext) -> None:
        def fail(event: CoreReady) -> None:
            raise ValueError("handler error")

        ctx.events.subscribe(CoreReady, fail)

    noisy = make_module("noisy", on_register=subscribe_failing)
    quiet = make_module("quiet")
    app = create_app(Settings(), modules=[noisy, quiet])

    with TestClient(app):
        pass

    assert [e.modules for e in quiet.events] == [("noisy", "quiet")]


def test_extension_default_and_priority():
    def provide(impl, priority):
        return lambda ctx: ctx.extensions.provide(COST_PROVIDER, impl, priority=priority)

    profile = CostProfile(eur_per_km=1.0)

    core_only = create_app(Settings(), modules=[])
    assert core_only.state.extensions.get(COST_PROVIDER).estimate(100, 0, profile) == 100

    app = create_app(
        Settings(),
        modules=[
            make_module("low", on_register=provide(DoubleCost(), 10)),
            make_module("high", on_register=provide(TripleCost(), 20)),
        ],
    )
    assert app.state.extensions.get(COST_PROVIDER).estimate(100, 0, profile) == 300
    assert app.state.extensions.owner(COST_PROVIDER) == "high"


def test_provider_breaking_contract_fails_module():
    app = create_app(
        Settings(),
        modules=[
            make_module("wrong", on_register=lambda ctx: ctx.extensions.provide(COST_PROVIDER, 42))
        ],
    )

    assert statuses(app) == {"wrong": ModuleState.FAILED}
