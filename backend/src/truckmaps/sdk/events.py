from datetime import UTC, datetime
from typing import ClassVar

from pydantic import BaseModel, ConfigDict, Field


class Event(BaseModel):
    """Bazowa klasa zdarzenia.

    Schematy zdarzeń wymienianych między modułami żyją w SDK, dzięki czemu
    moduły nie muszą (i nie mogą) importować się nawzajem.
    """

    model_config = ConfigDict(frozen=True)

    type: ClassVar[str]
    """Stały, wersjonowany typ, np. ``"route.calculated.v1"``."""

    occurred_at: datetime = Field(default_factory=lambda: datetime.now(UTC))


class CoreReady(Event):
    """Rdzeń załadował moduły i przyjmuje żądania."""

    type: ClassVar[str] = "core.ready.v1"

    modules: tuple[str, ...]
    """Identyfikatory aktywnych modułów."""
