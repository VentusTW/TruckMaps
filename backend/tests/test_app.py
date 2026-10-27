from fastapi.testclient import TestClient

from truckmaps.core.app import create_app
from truckmaps.core.config import Settings, load_env_file
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


def test_settings_oidc_from_env():
    settings = Settings.from_env(
        {
            "TRUCKMAPS_OIDC_ISSUER": "http://localhost:8080",
            "TRUCKMAPS_OIDC_CLIENT_ID": "c1",
            "TRUCKMAPS_PUBLIC_URL": "http://localhost:8000/",
        }
    )

    assert settings.oidc_enabled
    assert settings.public_url == "http://localhost:8000"
    assert not Settings.from_env({}).oidc_enabled


def test_load_env_file_keeps_existing_values(tmp_path):
    env_file = tmp_path / ".env"
    env_file.write_text("# komentarz\nA=z-pliku\nB=z-pliku\n", encoding="utf-8")
    env = {"A": "ustawione"}

    load_env_file(env_file, env)

    assert env == {"A": "ustawione", "B": "z-pliku"}


def test_settings_module_selection():
    assert Settings.from_env({}).enabled_modules is None
    assert Settings.from_env({"TRUCKMAPS_MODULES": "*"}).enabled_modules is None
    assert Settings.from_env({"TRUCKMAPS_MODULES": ""}).enabled_modules == frozenset()
