import logging
from collections.abc import Callable
from typing import Protocol

from fastapi import APIRouter

from truckmaps.sdk.auth import Auth
from truckmaps.sdk.events import Event
from truckmaps.sdk.extensions import ExtensionPoint


class ApiRegistry(Protocol):
    def include_router(self, router: APIRouter) -> None:
        """Podpina router pod ``/api/m/<id modułu>``.

        Rdzeń sam dokłada sprawdzenie licencji – endpointy modułu są dostępne
        tylko dla kont, które mają ten moduł wykupiony.
        """
        ...


class EventBus(Protocol):
    def publish(self, event: Event) -> None: ...

    def subscribe[E: Event](self, event_type: type[E], handler: Callable[[E], None]) -> None:
        """Błąd w ``handler`` jest logowany i nie wpływa na innych odbiorców."""
        ...


class Extensions(Protocol):
    def provide[T](self, point: ExtensionPoint[T], implementation: T, *, priority: int = 0) -> None:
        """Zgłasza implementację gniazda; wygrywa najwyższy priorytet."""
        ...

    def get[T](self, point: ExtensionPoint[T]) -> T:
        """Zwraca aktualną implementację gniazda.

        Wywołuj w czasie obsługi żądania, nie w ``register`` – wtedy widać
        implementacje wszystkich załadowanych modułów.
        """
        ...


class CoreContext(Protocol):
    """To, co rdzeń udostępnia modułowi w ``Module.register``."""

    module_id: str
    core_version: str
    api: ApiRegistry
    auth: Auth
    events: EventBus
    extensions: Extensions
    logger: logging.Logger
