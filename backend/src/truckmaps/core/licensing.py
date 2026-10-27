from collections.abc import Callable, Mapping
from typing import Annotated

from fastapi import Header, HTTPException, status


class StaticLicensing:
    """Licencje z konfiguracji.

    Tymczasowe rozwiązanie fazy 0: konto przychodzi w nagłówku ``X-Account-Id``.
    W fazie 1 zastąpią je konta (JWT) i subskrypcje ze sklepów.
    """

    def __init__(self, licenses: Mapping[str, frozenset[str]], *, grant_all: bool = False) -> None:
        self._licenses = licenses
        self._grant_all = grant_all

    def is_granted(self, account_id: str | None, module_id: str) -> bool:
        if self._grant_all:
            return True
        return account_id is not None and module_id in self._licenses.get(account_id, ())

    def dependency(self, module_id: str) -> Callable[..., None]:
        def require_license(x_account_id: Annotated[str | None, Header()] = None) -> None:
            if not self.is_granted(x_account_id, module_id):
                raise HTTPException(
                    status.HTTP_402_PAYMENT_REQUIRED,
                    detail=f"Moduł '{module_id}' nie jest aktywny dla tego konta.",
                )

        return require_license
