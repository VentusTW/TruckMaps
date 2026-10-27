import os
from collections.abc import Mapping
from dataclasses import dataclass, field


@dataclass(frozen=True)
class Settings:
    enabled_modules: frozenset[str] | None = None
    """Moduły do załadowania; ``None`` oznacza wszystkie zainstalowane."""

    dev_grant_all: bool = False
    """Tryb deweloperski: każde konto ma każdy moduł."""

    licenses: Mapping[str, frozenset[str]] = field(default_factory=dict)
    """Konto → wykupione moduły. Tymczasowo, do czasu kont i subskrypcji (faza 1)."""

    @classmethod
    def from_env(cls, env: Mapping[str, str] = os.environ) -> "Settings":
        """Czyta ``TRUCKMAPS_MODULES``, ``TRUCKMAPS_DEV_GRANT_ALL`` i ``TRUCKMAPS_LICENSES``.

        ``TRUCKMAPS_MODULES``: brak lub ``*`` – wszystkie, pusty – sam rdzeń, ``a,b`` – wybrane.
        ``TRUCKMAPS_LICENSES``: ``konto1:hello,tolls;konto2:hello``.
        """
        modules = env.get("TRUCKMAPS_MODULES")
        enabled = None if modules is None or modules.strip() == "*" else _split(modules, ",")
        return cls(
            enabled_modules=enabled,
            dev_grant_all=env.get("TRUCKMAPS_DEV_GRANT_ALL", "").lower() in {"1", "true", "yes"},
            licenses=_parse_licenses(env.get("TRUCKMAPS_LICENSES", "")),
        )


def _split(value: str, sep: str) -> frozenset[str]:
    return frozenset(part.strip() for part in value.split(sep) if part.strip())


def _parse_licenses(value: str) -> dict[str, frozenset[str]]:
    licenses = {}
    for entry in _split(value, ";"):
        account, _, modules = entry.partition(":")
        licenses[account.strip()] = _split(modules, ",")
    return licenses
