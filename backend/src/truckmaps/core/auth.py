"""Uwierzytelnianie: weryfikacja tokenów OIDC (Zitadel) i zależności FastAPI."""

from collections.abc import Callable
from functools import cached_property
from typing import Annotated, Any, Protocol

import httpx
import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from truckmaps.core.i18n import t
from truckmaps.sdk import Principal

ORGANIZATION_CLAIM = "urn:zitadel:iam:user:resourceowner:id"


class InvalidToken(Exception):
    pass


class TokenVerifier(Protocol):
    def verify(self, token: str) -> Principal: ...


class OidcProvider:
    """Dostawca logowania OIDC: metadane, klucze i weryfikacja tokenów."""

    def __init__(
        self, issuer: str, client_id: str, *, project_id: str | None = None, jwks_client=None
    ) -> None:
        self.issuer = issuer.rstrip("/")
        self.client_id = client_id
        # Zitadel wpisuje do "aud" tokenu dostępu identyfikator aplikacji i projektu.
        self._audiences = [a for a in (client_id, project_id) if a]
        self._jwks_client = jwks_client

    @cached_property
    def metadata(self) -> dict[str, Any]:
        response = httpx.get(f"{self.issuer}/.well-known/openid-configuration", timeout=10)
        response.raise_for_status()
        return response.json()

    @property
    def jwks_client(self) -> jwt.PyJWKClient:
        if self._jwks_client is None:
            self._jwks_client = jwt.PyJWKClient(self.metadata["jwks_uri"], cache_keys=True)
        return self._jwks_client

    def verify(self, token: str) -> Principal:
        claims = self.decode(token, audience=self._audiences)
        return Principal(
            subject=claims["sub"],
            organization_id=claims.get(ORGANIZATION_CLAIM),
            claims=claims,
        )

    def decode(self, token: str, *, audience: str | list[str]) -> dict[str, Any]:
        try:
            key = self.jwks_client.get_signing_key_from_jwt(token).key
            return jwt.decode(
                token,
                key,
                algorithms=["RS256"],
                audience=audience,
                issuer=self.issuer,
                options={"require": ["exp", "iat", "iss", "sub"]},
            )
        except jwt.PyJWKClientConnectionError:
            raise
        except jwt.PyJWTError as exc:
            raise InvalidToken(str(exc)) from exc


_bearer = HTTPBearer(auto_error=False, description="Token dostępu z logowania TruckMaps")


class AuthService:
    """Zależności FastAPI udostępniane rdzeniowi i modułom (``CoreContext.auth``)."""

    def __init__(self, verifier: TokenVerifier | None) -> None:
        self.verifier = verifier

        def optional_user(
            credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
        ) -> Principal | None:
            if credentials is None:
                return None
            if self.verifier is None:
                raise _unauthorized("Logowanie nie jest skonfigurowane na tym serwerze.")
            try:
                return self.verifier.verify(credentials.credentials)
            except InvalidToken as exc:
                raise _unauthorized("Nieprawidłowy lub wygasły token.") from exc
            except jwt.PyJWKClientConnectionError as exc:
                raise HTTPException(
                    status.HTTP_503_SERVICE_UNAVAILABLE, t("error.login_server_unavailable")
                ) from exc

        def current_user(
            user: Annotated[Principal | None, Depends(optional_user)],
        ) -> Principal:
            if user is None:
                raise _unauthorized(t("error.login_required"))
            return user

        self.optional_user: Callable[..., Principal | None] = optional_user
        self.current_user: Callable[..., Principal] = current_user


def _unauthorized(detail: str) -> HTTPException:
    return HTTPException(
        status.HTTP_401_UNAUTHORIZED, detail, headers={"WWW-Authenticate": "Bearer"}
    )
