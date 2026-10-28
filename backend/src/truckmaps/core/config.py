import os
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    enabled_modules: frozenset[str] | None = None
    """Moduły do załadowania; ``None`` oznacza wszystkie zainstalowane."""

    dev_grant_all: bool = False
    """Tryb deweloperski: każdy (także niezalogowany) ma każdy moduł."""

    licenses: Mapping[str, frozenset[str]] = field(default_factory=dict)
    """Identyfikator użytkownika (``sub``) → wykupione moduły. Tymczasowo, do czasu subskrypcji."""

    oidc_issuer: str | None = None
    """Adres dostawcy logowania (Zitadel); ``None`` wyłącza logowanie."""

    oidc_client_id: str | None = None
    oidc_project_id: str | None = None

    public_url: str = "http://localhost:8000"
    """Adres, pod którym użytkownik widzi serwer – do przekierowań po logowaniu."""

    dev_login_page: bool = False
    """Strona ``/`` z testowym logowaniem w przeglądarce."""

    database_url: str | None = None
    """Np. ``postgresql+psycopg://truckmaps:...@localhost:5432/truckmaps``; ``None`` – bez bazy."""

    valhalla_url: str = "http://127.0.0.1:8002"

    @property
    def oidc_enabled(self) -> bool:
        return bool(self.oidc_issuer and self.oidc_client_id)

    @classmethod
    def from_env(cls, env: Mapping[str, str] = os.environ) -> "Settings":
        """Czyta zmienne ``TRUCKMAPS_*``.

        ``TRUCKMAPS_MODULES``: brak lub ``*`` – wszystkie, pusty – sam rdzeń, ``a,b`` – wybrane.
        ``TRUCKMAPS_LICENSES``: ``sub1:hello,tolls;sub2:hello``.
        ``TRUCKMAPS_OIDC_ISSUER``, ``TRUCKMAPS_OIDC_CLIENT_ID``, ``TRUCKMAPS_OIDC_PROJECT_ID``:
        zapisuje je ``infra/zitadel/bootstrap.py``.
        """
        modules = env.get("TRUCKMAPS_MODULES")
        enabled = None if modules is None or modules.strip() == "*" else _split(modules, ",")
        return cls(
            enabled_modules=enabled,
            dev_grant_all=_flag(env, "TRUCKMAPS_DEV_GRANT_ALL"),
            licenses=_parse_licenses(env.get("TRUCKMAPS_LICENSES", "")),
            oidc_issuer=env.get("TRUCKMAPS_OIDC_ISSUER") or None,
            oidc_client_id=env.get("TRUCKMAPS_OIDC_CLIENT_ID") or None,
            oidc_project_id=env.get("TRUCKMAPS_OIDC_PROJECT_ID") or None,
            public_url=env.get("TRUCKMAPS_PUBLIC_URL", cls.public_url).rstrip("/"),
            dev_login_page=_flag(env, "TRUCKMAPS_DEV_LOGIN"),
            database_url=env.get("TRUCKMAPS_DATABASE_URL") or None,
            valhalla_url=env.get("TRUCKMAPS_VALHALLA_URL", cls.valhalla_url),
        )


def load_env_file(path: Path, env: dict[str, str] | None = None) -> None:
    """Wczytuje ``KLUCZ=wartość`` z pliku; zmienne już ustawione mają pierwszeństwo."""
    env = os.environ if env is None else env
    if not path.is_file():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        key, sep, value = line.partition("=")
        if sep and not line.lstrip().startswith("#"):
            env.setdefault(key.strip(), value.strip())


def _flag(env: Mapping[str, str], name: str) -> bool:
    return env.get(name, "").lower() in {"1", "true", "yes"}


def _split(value: str, sep: str) -> frozenset[str]:
    return frozenset(part.strip() for part in value.split(sep) if part.strip())


def _parse_licenses(value: str) -> dict[str, frozenset[str]]:
    licenses = {}
    for entry in _split(value, ";"):
        account, _, modules = entry.partition(":")
        licenses[account.strip()] = _split(modules, ",")
    return licenses
