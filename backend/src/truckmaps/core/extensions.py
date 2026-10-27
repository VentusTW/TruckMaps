from dataclasses import dataclass
from itertools import count

from truckmaps.sdk import ExtensionPoint


@dataclass(frozen=True)
class _Provider:
    priority: int
    order: int
    owner: str
    implementation: object


class ExtensionRegistry:
    """Implementacje gniazd: domyślna z rdzenia + dostarczone przez moduły."""

    def __init__(self) -> None:
        self._defaults: dict[str, object] = {}
        self._providers: dict[str, list[_Provider]] = {}
        self._order = count()

    def set_default[T](self, point: ExtensionPoint[T], implementation: T) -> None:
        check_implementation(point, implementation)
        self._defaults[point.key] = implementation

    def provide[T](
        self, point: ExtensionPoint[T], implementation: T, *, priority: int = 0, owner: str = "core"
    ) -> None:
        check_implementation(point, implementation)
        provider = _Provider(priority, next(self._order), owner, implementation)
        self._providers.setdefault(point.key, []).append(provider)

    def get[T](self, point: ExtensionPoint[T]) -> T:
        providers = self._providers.get(point.key)
        if providers:
            # Najwyższy priorytet; przy remisie wygrywa zarejestrowany wcześniej.
            best = max(providers, key=lambda p: (p.priority, -p.order))
            return best.implementation  # type: ignore[return-value]
        if point.key in self._defaults:
            return self._defaults[point.key]  # type: ignore[return-value]
        raise LookupError(f"Brak implementacji gniazda '{point.key}'")

    def owner(self, point: ExtensionPoint) -> str:
        """Kto dostarcza aktualną implementację – do diagnostyki."""
        providers = self._providers.get(point.key)
        if providers:
            return max(providers, key=lambda p: (p.priority, -p.order)).owner
        return "core"


def check_implementation(point: ExtensionPoint, implementation: object) -> None:
    if not isinstance(implementation, point.protocol):
        raise TypeError(
            f"{type(implementation).__name__} nie spełnia kontraktu gniazda '{point.key}'"
        )
