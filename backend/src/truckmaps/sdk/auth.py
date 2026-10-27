from collections.abc import Callable
from typing import Any, Protocol

from pydantic import BaseModel, ConfigDict, Field


class Principal(BaseModel):
    """Zalogowany użytkownik, niezależnie od tego, kto wystawił token."""

    model_config = ConfigDict(frozen=True)

    subject: str
    """Stały identyfikator użytkownika u dostawcy logowania."""

    organization_id: str | None = None
    """Firma / flota, do której należy użytkownik."""

    claims: dict[str, Any] = Field(default_factory=dict, repr=False)


class Auth(Protocol):
    @property
    def current_user(self) -> Callable[..., Principal]:
        """Zależność FastAPI zwracająca zalogowanego użytkownika (401, gdy go brak).

        Użycie: ``user: Annotated[Principal, Depends(ctx.auth.current_user)]``.
        """
        ...
