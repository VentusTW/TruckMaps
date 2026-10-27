"""Pilnuje, żeby każdy moduł był objęty kontraktami import-linter."""

import configparser
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def _module_packages() -> set[str]:
    packages = set()
    for src in (REPO / "backend" / "modules").glob("*/src"):
        packages.update(p.name for p in src.iterdir() if (p / "__init__.py").exists())
    return packages


def _contract_values(config: configparser.ConfigParser, contract: str, key: str) -> set[str]:
    return set(config[f"importlinter:contract:{contract}"][key].split())


def test_every_module_is_covered_by_import_contracts():
    config = configparser.ConfigParser()
    config.read(REPO / ".importlinter", encoding="utf-8")
    packages = _module_packages()

    assert packages, "Nie znaleziono żadnego modułu w backend/modules"
    assert packages <= set(config["importlinter"]["root_packages"].split())
    assert packages <= _contract_values(config, "modules-use-sdk-only", "source_modules")
    assert packages <= _contract_values(config, "core-knows-no-modules", "forbidden_modules")
    assert packages <= _contract_values(config, "modules-independent", "modules")
