import logging
from collections import defaultdict
from collections.abc import Callable

from truckmaps.sdk import Event

log = logging.getLogger(__name__)


class InProcessEventBus:
    """Synchroniczna szyna zdarzeń w procesie.

    Błąd w obsłudze zdarzenia przez jeden moduł jest logowany i nie przerywa
    dostarczania do pozostałych. Później można ją podmienić na Redis Streams
    lub NATS bez zmian w modułach.
    """

    def __init__(self) -> None:
        self._handlers: defaultdict[type[Event], list[tuple[str, Callable]]] = defaultdict(list)

    def subscribe[E: Event](
        self, event_type: type[E], handler: Callable[[E], None], *, owner: str = "core"
    ) -> None:
        self._handlers[event_type].append((owner, handler))

    def publish(self, event: Event) -> None:
        for owner, handler in list(self._handlers[type(event)]):
            try:
                handler(event)
            except Exception:
                log.exception("Błąd obsługi zdarzenia %s w module %s", event.type, owner)
