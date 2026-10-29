"""Tłumaczenia tekstów dla użytkownika.

Teksty są w katalogach ``{klucz: szablon}`` dla każdego języka (rdzeń: pliki
``truckmaps/core/locales/<język>.json``; moduł dodaje własne przez :func:`register`).
Język bieżącego zapytania ustawia rdzeń z nagłówka ``Accept-Language``; bez niego –
polski. Brakujący tekst w danym języku → tekst polski.

    t("route.bend", radius=12)          # "Ostry zakręt – promień ok. 12 m"
    num(4.05)                           # "4,05" po polsku, "4.05" po angielsku

Do wartości zapamiętywanych między zapytaniami (np. w ``lru_cache``) służy
:class:`Msg` – tekst tłumaczony dopiero przy wyświetleniu.
"""

from collections.abc import Iterator, Mapping
from contextlib import contextmanager
from contextvars import ContextVar
from typing import NamedTuple

DEFAULT_LANGUAGE = "pl"

_catalogs: dict[str, dict[str, str]] = {}
_language: ContextVar[str] = ContextVar("truckmaps_language", default=DEFAULT_LANGUAGE)


class Msg(NamedTuple):
    """Tekst do przetłumaczenia później: klucz i parametry (niezmienny, można go haszować)."""

    key: str
    params: tuple[tuple[str, object], ...] = ()

    @classmethod
    def of(cls, key: str, /, **params: object) -> "Msg":
        return cls(key, tuple(sorted(params.items())))


def register(language: str, entries: Mapping[str, str]) -> None:
    """Dodaje teksty w danym języku (np. z pliku JSON modułu)."""
    _catalogs.setdefault(language, {}).update(entries)


def languages() -> list[str]:
    return sorted(_catalogs)


def catalog(language: str) -> dict[str, str]:
    return dict(_catalogs.get(language, {}))


def language() -> str:
    """Język bieżącego zapytania."""
    return _language.get()


@contextmanager
def use(language: str) -> Iterator[None]:
    token = _language.set(language)
    try:
        yield
    finally:
        _language.reset(token)


def negotiate(header: str | None) -> str:
    """Najlepszy dostępny język z nagłówka ``Accept-Language`` (np. "de-DE,de;q=0.9,en;q=0.8")."""
    if not header:
        return DEFAULT_LANGUAGE
    ranked = []
    for position, part in enumerate(header.split(",")):
        tag, _, params = part.strip().partition(";")
        quality = 1.0
        if params.strip().startswith("q="):
            try:
                quality = float(params.strip()[2:])
            except ValueError:
                quality = 0.0
        ranked.append((-quality, position, tag.strip().lower()))
    for quality, _, tag in sorted(ranked):
        primary = tag.split("-")[0]
        if quality < 0 and primary in _catalogs:
            return primary
    return DEFAULT_LANGUAGE


def t(key: "str | Msg", /, **params: object) -> str:
    """Tekst w języku bieżącego zapytania. Liczby z ułamkiem – z separatorem tego języka."""
    if isinstance(key, Msg):
        params = dict(key.params) | params
        key = key.key
    template = _lookup(key) or key
    return template.format(**{name: _value(value) for name, value in params.items()})


def num(value: float, digits: int = 2, *, trim: bool = True) -> str:
    """Liczba z separatorem dziesiętnym języka; ``trim`` usuwa zbędne zera ("4,10" → "4,1")."""
    text = f"{value:.{digits}f}"
    if trim and "." in text:
        text = text.rstrip("0").rstrip(".")
    return text.replace(".", _lookup("number.decimal_separator") or ",")


def _lookup(key: str) -> str | None:
    found = _catalogs.get(language(), {}).get(key)
    return found if found is not None else _catalogs.get(DEFAULT_LANGUAGE, {}).get(key)


def _value(value: object) -> object:
    if isinstance(value, Msg):
        return t(value)
    if isinstance(value, float):
        return num(value)
    return value
