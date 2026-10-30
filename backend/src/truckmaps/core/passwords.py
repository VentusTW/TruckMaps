"""Hasło konta: link do ustawienia nowego hasła e-mailem i zmiana hasła w ustawieniach.

Konto i hasło są u dostawcy logowania (Zitadel). Serwer prosi go o to kontem technicznym
(``TRUCKMAPS_ZITADEL_TOKEN``, rola ORG_USER_MANAGER – zakłada je ``infra/zitadel/bootstrap.py``).
Hasło nigdy nie jest wysyłane e-mailem: Zitadel wysyła jednorazowy link, pod którym
użytkownik sam ustawia nowe hasło.
"""

import re
import threading
import time
from collections import defaultdict, deque
from typing import Annotated, Protocol

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from pydantic import BaseModel, Field, StringConstraints

from truckmaps.core.i18n import t
from truckmaps.sdk import Principal

RESET_LIMIT = 3
"""Ile próśb o link na ten sam adres w ciągu ``RESET_WINDOW_S`` (ochrona skrzynek przed spamem)."""
RESET_WINDOW_S = 3600
MIN_LENGTH = 8


class WrongPassword(Exception):
    """Obecne hasło się nie zgadza (albo dostawca logowania odrzucił nowe)."""


class PasswordService(Protocol):
    def request_reset(self, email: str) -> None:
        """Wysyła link do ustawienia nowego hasła; nieznany adres – nic się nie dzieje."""

    def change(self, subject: str, current: str, new: str) -> None:
        """Zmienia hasło po sprawdzeniu obecnego; zły obecny → ``WrongPassword``."""


class ZitadelPasswords:
    """Hasła w Zitadelu przez API v2 (konto techniczne z rolą ORG_USER_MANAGER)."""

    def __init__(self, issuer: str, token: str, client: httpx.Client | None = None) -> None:
        self._client = client or httpx.Client(
            base_url=issuer, headers={"Authorization": f"Bearer {token}"}, timeout=20
        )

    def request_reset(self, email: str) -> None:
        query = {"emailAddress": email, "method": "TEXT_QUERY_METHOD_EQUALS_IGNORE_CASE"}
        found = self._client.post("/v2/users", json={"queries": [{"emailQuery": query}]})
        found.raise_for_status()
        for user in found.json().get("result", []):
            self._client.post(
                f"/v2/users/{user['userId']}/password_reset",
                json={"sendLink": {"notificationType": "NOTIFICATION_TYPE_Email"}},
            ).raise_for_status()

    def change(self, subject: str, current: str, new: str) -> None:
        response = self._client.post(
            f"/v2/users/{subject}/password",
            json={
                "newPassword": {"password": new, "changeRequired": False},
                "currentPassword": current,
            },
        )
        if response.status_code in (400, 412):
            raise WrongPassword(response.text)
        response.raise_for_status()


def weak_password(password: str) -> bool:
    """Te same zasady co domyślne w Zitadelu: 8 znaków, wielka i mała litera, cyfra, symbol."""
    return not (
        len(password) >= MIN_LENGTH
        and re.search(r"[A-Z]", password)
        and re.search(r"[a-z]", password)
        and re.search(r"\d", password)
        and re.search(r"[^A-Za-z0-9]", password)
    )


class ResetIn(BaseModel):
    email: Annotated[
        str,
        StringConstraints(
            strip_whitespace=True, max_length=254, pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$"
        ),
    ]


class ResetOut(BaseModel):
    detail: str


class ChangeIn(BaseModel):
    current_password: str = Field(min_length=1, max_length=200)
    new_password: str = Field(max_length=200)


class _Limiter:
    """Prośby o link na adres – w pamięci serwera (po restarcie liczymy od nowa)."""

    def __init__(self) -> None:
        self._seen: dict[str, deque[float]] = defaultdict(deque)
        self._lock = threading.Lock()

    def allow(self, key: str) -> bool:
        now = time.monotonic()
        with self._lock:
            seen = self._seen[key]
            while seen and now - seen[0] > RESET_WINDOW_S:
                seen.popleft()
            if len(seen) >= RESET_LIMIT:
                return False
            seen.append(now)
            return True


def build_router(current_user) -> APIRouter:
    router = APIRouter(tags=["passwords"])
    User = Annotated[Principal, Depends(current_user)]
    limiter = _Limiter()

    def service(request: Request) -> PasswordService:
        passwords = request.app.state.passwords
        if passwords is None:
            raise HTTPException(
                status.HTTP_503_SERVICE_UNAVAILABLE, t("error.password_service_unavailable")
            )
        return passwords

    @router.post("/api/auth/password-reset", status_code=status.HTTP_202_ACCEPTED)
    def password_reset(data: ResetIn, request: Request) -> ResetOut:
        """Link do ustawienia nowego hasła. Odpowiedź ta sama, czy konto istnieje, czy nie –
        inaczej formularz zdradzałby, kto ma konto."""
        passwords = service(request)
        email = data.email.strip().lower()
        if limiter.allow(email):
            try:
                passwords.request_reset(email)
            except httpx.HTTPError as exc:
                raise HTTPException(
                    status.HTTP_503_SERVICE_UNAVAILABLE, t("error.login_server_unavailable")
                ) from exc
        return ResetOut(detail=t("password.reset_sent"))

    @router.post("/api/me/password", status_code=status.HTTP_204_NO_CONTENT)
    def change_password(data: ChangeIn, user: User, request: Request) -> Response:
        passwords = service(request)
        if weak_password(data.new_password):
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, t("error.password_weak"))
        try:
            passwords.change(user.subject, data.current_password, data.new_password)
        except WrongPassword as exc:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST, t("error.password_wrong_current")
            ) from exc
        except httpx.HTTPError as exc:
            raise HTTPException(
                status.HTTP_503_SERVICE_UNAVAILABLE, t("error.login_server_unavailable")
            ) from exc
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    return router
