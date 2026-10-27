from fastapi.testclient import TestClient

from truckmaps.core.app import create_app
from truckmaps.core.config import Settings
from truckmaps.core.version import CORE_VERSION


def test_core_runs_without_modules():
    app = create_app(Settings(), modules=[])

    with TestClient(app) as client:
        assert client.get("/api/health").json() == {"status": "ok", "core_version": CORE_VERSION}
        assert client.get("/api/modules").json() == []


def test_settings_from_env():
    settings = Settings.from_env(
        {
            "TRUCKMAPS_MODULES": "hello, tolls",
            "TRUCKMAPS_DEV_GRANT_ALL": "true",
            "TRUCKMAPS_LICENSES": "acc-1:hello,tolls; acc-2:hello",
        }
    )

    assert settings.enabled_modules == {"hello", "tolls"}
    assert settings.dev_grant_all is True
    assert settings.licenses == {"acc-1": {"hello", "tolls"}, "acc-2": {"hello"}}


def test_settings_module_selection():
    assert Settings.from_env({}).enabled_modules is None
    assert Settings.from_env({"TRUCKMAPS_MODULES": "*"}).enabled_modules is None
    assert Settings.from_env({"TRUCKMAPS_MODULES": ""}).enabled_modules == frozenset()
