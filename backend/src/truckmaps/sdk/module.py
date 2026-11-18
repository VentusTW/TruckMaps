from __future__ import annotations

from abc import ABC, abstractmethod
from collections.abc import Mapping
from typing import TYPE_CHECKING, ClassVar

if TYPE_CHECKING:
    from truckmaps.sdk.context import CoreContext


class Module(ABC):
    """Bazowa klasa modułu TruckMaps.

    Moduł jest instalowany jako osobna paczka i zgłaszany przez entry point
    w grupie ``truckmaps.modules``; nazwa entry pointu musi być równa ``id``.
    """

    id: ClassVar[str]
    """Stały identyfikator: małe litery, cyfry, ``_``. Wyznacza prefiks API ``/api/m/<id>``."""

    name: ClassVar[str]
    names: ClassVar[Mapping[str, str]] = {}
    """Nazwa w językach użytkownika ``{"en": "Documents", …}``.

    Brak języka – nazwa angielska, a bez niej ``name`` (po polsku).
    """
    version: ClassVar[str]

    requires_core: ClassVar[str]
    """Wymagana wersja rdzenia jako specyfikator PEP 440, np. ``">=0.1,<1.0"``."""

    @abstractmethod
    def register(self, ctx: CoreContext) -> None:
        """Podłącza moduł do rdzenia: routery, subskrypcje zdarzeń, punkty rozszerzeń.

        Jeśli metoda rzuci wyjątek, nic z tego, co zarejestrowała, nie zostanie
        włączone, a reszta systemu działa dalej.
        """
