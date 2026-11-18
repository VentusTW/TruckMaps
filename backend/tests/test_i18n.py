import json
import re
from datetime import date
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from truckmaps.core import i18n, timebans
from truckmaps.core.app import create_app
from truckmaps.core.config import Settings
from truckmaps.core.restrictions import Kind, Restriction
from truckmaps.core.route_analysis import _compare
from truckmaps.core.vehicles import VehicleIn
from truckmaps.sdk.i18n import languages, negotiate, pick, register, t

PLACEHOLDER = re.compile(r"\{(\w+)\}")


ROOT = Path(__file__).parents[2]
# Rdzeń i każdy moduł mają własny katalog tekstów; moduł może mieć mniej języków niż rdzeń
# (brakujący język – teksty angielskie), ale każdy jego plik ma komplet kluczy.
LOCALE_FILES = [
    file
    for folder in [
        ROOT / "backend/src/truckmaps/core/locales",
        *ROOT.glob("backend/modules/*/src/*/locales"),
    ]
    for file in sorted(folder.glob("*.json"))
    if file.name != "pl.json"
]
CORE_LANGUAGES = {"pl", "en", "de", "cs", "sk", "lt", "ro", "uk"}


@pytest.mark.parametrize("path", LOCALE_FILES, ids=lambda p: f"{p.parent.parent.name}/{p.name}")
def test_every_language_has_all_texts_with_same_placeholders(path):
    polish = json.loads((path.parent / "pl.json").read_text("utf-8"))
    other = json.loads(path.read_text("utf-8"))

    assert sorted(set(polish) - set(other)) == []
    assert sorted(set(other) - set(polish)) == []
    for key, text in polish.items():
        assert set(PLACEHOLDER.findall(other[key])) == set(PLACEHOLDER.findall(text)), key


def test_core_languages():
    assert set(languages()) >= CORE_LANGUAGES
    assert "en" in {p.stem for p in LOCALE_FILES}


def test_missing_text_falls_back_to_english_then_polish():
    register("pl", {"test.only_pl": "tylko PL", "test.both": "PL"})
    register("en", {"test.both": "EN"})
    with i18n.use("de"):
        assert (t("test.both"), t("test.only_pl")) == ("EN", "tylko PL")
    assert pick({"pl": "Kierowcy", "en": "Drivers", "de": "Fahrer"}, "de") == "Fahrer"
    assert pick({"pl": "Kierowcy", "en": "Drivers"}, "lt") == "Drivers"


def test_language_from_accept_language():
    assert negotiate(None) == "pl"
    assert negotiate("en-GB,en;q=0.9") == "en"
    assert negotiate("de-DE,de;q=0.9,en;q=0.8") == "de"
    assert negotiate("uk-UA") == "uk"
    assert negotiate("en;q=0.5,pl;q=0.9") == "pl"
    assert negotiate("fr") == "pl"
    assert negotiate("en;q=0") == "pl"


def test_numbers_and_texts_in_language():
    vehicle = VehicleIn(
        name="Zestaw", height_m=4.0, width_m=2.55, length_m=16.5, weight_t=40,
        axle_load_t=11.5, axle_count=5,
    )  # fmt: skip
    sign = Restriction(kind=Kind.HEIGHT, value=3.5, raw="maxheight=3.5")

    assert _compare(sign, vehicle)[1] == "Ograniczenie wysokości 3,5 m (znak), pojazd 4 m"
    with i18n.use("en"):
        assert _compare(sign, vehicle)[1] == "Height limit 3.5 m (sign), vehicle 4 m"
        assert i18n.num(12.0, 1, trim=False) == "12.0"
    assert i18n.num(12.0, 1, trim=False) == "12,0"


def test_cached_ban_windows_are_translated_when_shown():
    (window,) = timebans.windows("PL", date(2026, 11, 1))

    assert i18n.t(window.title) == "święto (Wszystkich Świętych)"
    with i18n.use("en"):
        assert i18n.t(window.title) == "public holiday (Wszystkich Świętych)"


def test_api_answers_in_requested_language():
    app = create_app(Settings(), modules=[])

    with TestClient(app) as client:
        polish = client.get("/api/me")
        english = client.get("/api/me", headers={"Accept-Language": "en-US,en;q=0.9"})

    assert (polish.status_code, polish.json()["detail"]) == (401, "Wymagane logowanie.")
    assert polish.headers["content-language"] == "pl"
    assert english.json()["detail"] == "Login required."
    assert english.headers["content-language"] == "en"


@pytest.mark.parametrize("language", sorted(CORE_LANGUAGES))
def test_planner_page_is_translated(language):
    from truckmaps.core.devlogin import planner_page

    with i18n.use(language):
        page = planner_page('"token"', '"Jan"')
    assert "{{" not in page and "__TEXTS__" not in page and "__LANG__" not in page
    assert f'<html lang="{language}">' in page
    used = set(re.findall(r'T\("(planner\.\w+)"', page)) | {
        f"planner.level_{level}" for level in ("green", "lime", "yellow", "orange", "red")
    }
    texts = json.loads(re.search(r"const TEXTS = (\{.*?\});\n", page).group(1))
    assert sorted(used - set(texts)) == []
