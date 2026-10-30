from collections.abc import Callable, Mapping
from typing import Annotated

from fastapi import Depends, HTTPException, status

from truckmaps.core.i18n import t
from truckmaps.sdk import Principal


class StaticLicensing:
    """Licencje z konfiguracji, przypisane do identyfikatora zalogowanego użytkownika.

    Tymczasowo, do czasu subskrypcji ze sklepów i panelu floty.
    """

    def __init__(
        self,
        licenses: Mapping[str, frozenset[str]],
        *,
        optional_user: Callable[..., Principal | None],
        grant_all: bool = False,
    ) -> None:
        self._licenses = licenses
        self._optional_user = optional_user
        self._grant_all = grant_all

    @property
    def grants_all(self) -> bool:
        return self._grant_all

    def assignments(self) -> Mapping[str, frozenset[str]]:
        """Konto → moduły (do wglądu w programie administracyjnym)."""
        return self._licenses

    def is_granted(self, user: Principal | None, module_id: str) -> bool:
        if self._grant_all:
            return True
        return user is not None and module_id in self._licenses.get(user.subject, ())

    def dependency(self, module_id: str) -> Callable[..., None]:
        def require_license(
            user: Annotated[Principal | None, Depends(self._optional_user)],
        ) -> None:
            if self.is_granted(user, module_id):
                return
            if user is None:
                raise HTTPException(
                    status.HTTP_401_UNAUTHORIZED,
                    t("error.login_required"),
                    headers={"WWW-Authenticate": "Bearer"},
                )
            raise HTTPException(
                status.HTTP_402_PAYMENT_REQUIRED,
                detail=t("error.module_not_active", module=module_id),
            )

        return require_license
