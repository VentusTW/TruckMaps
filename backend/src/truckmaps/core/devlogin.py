"""Strona powitalna z testowym logowaniem (OIDC + PKCE) – do czasu aplikacji Flutter.

Przechodzi ten sam przepływ co docelowa aplikacja: przekierowanie do Zitadela,
powrót z kodem, wymiana kodu na tokeny. Tokeny trzyma w ciasteczkach httpOnly.

Aplikacja Flutter (na komputerze, w trakcie budowy) loguje się tak samo przez przeglądarkę:
``/auth/login?app=http://127.0.0.1:<port>/callback`` – po zalogowaniu serwer wraca na ten
adres lokalny z jednorazowym kodem (RFC 8252, przekierowanie na loopback), a aplikacja
wymienia kod na token przez ``POST /auth/app/token``. Token nie trafia do adresu.
Aplikacja dostaje też token odświeżania (``offline_access``) – ``POST /auth/app/refresh``
daje nowy token dostępu bez ponownego logowania.
"""

import base64
import hashlib
import html
import json
import secrets
import time
from importlib import resources
from urllib.parse import urlencode, urlparse

import httpx
from fastapi import APIRouter, HTTPException, Request, status
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from pydantic import BaseModel

from truckmaps.core.auth import InvalidToken, OidcProvider
from truckmaps.core.i18n import t

FLOW_COOKIE = "tm_flow"
ACCESS_COOKIE = "tm_access"
ID_COOKIE = "tm_id"
SCOPES = "openid profile email"
# Aplikacja zostaje zalogowana między uruchomieniami – potrzebuje tokenu odświeżania.
APP_SCOPES = f"{SCOPES} offline_access"
APP_CODE_TTL_S = 120
LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "[::1]", "::1"}


class AppCode(BaseModel):
    code: str


class AppToken(BaseModel):
    access_token: str
    expires_in: int
    name: str
    refresh_token: str | None = None


class AppRefresh(BaseModel):
    refresh_token: str


def build_router(provider: OidcProvider, public_url: str, http: httpx.Client | None = None):
    router = APIRouter(include_in_schema=False)
    http = http or httpx.Client(timeout=15)
    redirect_uri = f"{public_url}/auth/callback"
    # Jednorazowe kody dla aplikacji: kod → (ważny do, token).
    app_codes: dict[str, tuple[float, AppToken]] = {}

    @router.get("/")
    def welcome(request: Request, error: str | None = None) -> Response:
        user = _session_user(request, provider)
        if user is None:
            response = HTMLResponse(_page(_logged_out(error)))
            for name in (ACCESS_COOKIE, ID_COOKIE):
                if name in request.cookies:
                    response.delete_cookie(name)
            return response
        return HTMLResponse(_page(_logged_in(user, request.cookies[ACCESS_COOKIE])))

    @router.get("/planer")
    def planner(request: Request) -> Response:
        user = _session_user(request, provider)
        if user is None:
            return RedirectResponse("/", status_code=303)
        # Strona testowa woła API z nagłówkiem Bearer, więc dostaje token w kodzie strony.
        token = _js(request.cookies[ACCESS_COOKIE])
        template = resources.files("truckmaps.core").joinpath("templates/planner.html")
        page = template.read_text(encoding="utf-8").replace("__ACCESS_TOKEN__", token)
        # Nazwa widoczna dla innych członków firmy (token dostępu nie zawiera nazwiska).
        return HTMLResponse(page.replace("__USER_NAME__", _js(user["name"] or user["email"])))

    @router.get("/auth/login")
    def login(register: bool = False, app: str | None = None) -> Response:
        if app is not None and not _loopback(app):
            return _back_with_error("Aplikacja może wrócić tylko na adres lokalny (127.0.0.1).")
        state, nonce = secrets.token_urlsafe(24), secrets.token_urlsafe(24)
        verifier = secrets.token_urlsafe(64)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest())
        params = {
            "client_id": provider.client_id,
            "redirect_uri": redirect_uri,
            "response_type": "code",
            "scope": APP_SCOPES if app is not None else SCOPES,
            "state": state,
            "nonce": nonce,
            "code_challenge": challenge.rstrip(b"=").decode(),
            "code_challenge_method": "S256",
        }
        if register:
            params["prompt"] = "create"
        url = f"{provider.metadata['authorization_endpoint']}?{urlencode(params)}"
        response = RedirectResponse(url)
        flow = {"state": state, "nonce": nonce, "verifier": verifier}
        if app is not None:
            flow["app"] = app
        flow = encode_flow(flow)
        response.set_cookie(FLOW_COOKIE, flow, max_age=600, httponly=True, samesite="lax")
        return response

    @router.get("/auth/callback")
    def callback(
        request: Request,
        code: str | None = None,
        state: str | None = None,
        error: str | None = None,
    ) -> Response:
        if error:
            return _back_with_error(f"Logowanie przerwane ({error}).")
        flow = decode_flow(request.cookies.get(FLOW_COOKIE, ""))
        if not flow or not code or not secrets.compare_digest(flow["state"], state or ""):
            return _back_with_error("Sesja logowania wygasła. Spróbuj ponownie.")

        token_response = http.post(
            provider.metadata["token_endpoint"],
            data={
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirect_uri,
                "client_id": provider.client_id,
                "code_verifier": flow["verifier"],
            },
        )
        if token_response.is_error:
            return _back_with_error("Nie udało się dokończyć logowania.")
        tokens = token_response.json()
        try:
            provider.verify(tokens["access_token"])
            id_claims = provider.decode(tokens["id_token"], audience=provider.client_id)
        except (KeyError, InvalidToken):
            return _back_with_error("Serwer logowania zwrócił nieprawidłowy token.")
        if id_claims.get("nonce") != flow["nonce"]:
            return _back_with_error("Nieprawidłowa odpowiedź serwera logowania.")

        max_age = int(tokens.get("expires_in", 3600))
        if app := flow.get("app"):
            now = time.monotonic()
            for old in [c for c, (until, _) in app_codes.items() if until < now]:
                del app_codes[old]
            code = secrets.token_urlsafe(24)
            name = id_claims.get("name") or id_claims.get("email") or ""
            app_codes[code] = (
                now + APP_CODE_TTL_S,
                AppToken(
                    access_token=tokens["access_token"],
                    expires_in=max_age,
                    name=name,
                    refresh_token=tokens.get("refresh_token"),
                ),
            )
            separator = "&" if "?" in app else "?"
            response = RedirectResponse(f"{app}{separator}{urlencode({'code': code})}", 303)
            response.delete_cookie(FLOW_COOKIE)
            return response
        response = RedirectResponse(f"{public_url}/", status_code=303)
        for name, value in (
            (ACCESS_COOKIE, tokens["access_token"]),
            (ID_COOKIE, tokens["id_token"]),
        ):
            response.set_cookie(name, value, max_age=max_age, httponly=True, samesite="lax")
        response.delete_cookie(FLOW_COOKIE)
        return response

    @router.post("/auth/app/token")
    def app_token(data: AppCode) -> AppToken:
        """Token dla aplikacji w zamian za jednorazowy kod z przekierowania na loopback."""
        found = app_codes.pop(data.code, None)
        if found is None or found[0] < time.monotonic():
            raise HTTPException(status.HTTP_400_BAD_REQUEST, t("error.login_code_invalid"))
        return found[1]

    @router.post("/auth/app/refresh")
    def app_refresh(data: AppRefresh) -> AppToken:
        """Nowy token dostępu z tokenu odświeżania (aplikacja zostaje zalogowana)."""
        response = http.post(
            provider.metadata["token_endpoint"],
            data={
                "grant_type": "refresh_token",
                "refresh_token": data.refresh_token,
                "client_id": provider.client_id,
            },
        )
        if response.is_error:
            raise HTTPException(
                status.HTTP_401_UNAUTHORIZED, t("error.session_expired_login_again")
            )
        tokens = response.json()
        try:
            provider.verify(tokens["access_token"])
        except (KeyError, InvalidToken):
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, t("error.session_expired")) from None
        try:
            claims = provider.decode(tokens["id_token"], audience=provider.client_id)
        except (KeyError, InvalidToken):
            claims = {}  # nazwa użytkownika jest opcjonalna – aplikacja ma ją z logowania
        return AppToken(
            access_token=tokens["access_token"],
            expires_in=int(tokens.get("expires_in", 3600)),
            name=claims.get("name") or claims.get("email") or "",
            refresh_token=tokens.get("refresh_token") or data.refresh_token,
        )

    @router.get("/auth/logout")
    def logout(request: Request) -> Response:
        params = {"client_id": provider.client_id, "post_logout_redirect_uri": f"{public_url}/"}
        if id_token := request.cookies.get(ID_COOKIE):
            params["id_token_hint"] = id_token
        response = RedirectResponse(
            f"{provider.metadata['end_session_endpoint']}?{urlencode(params)}"
        )
        for name in (ACCESS_COOKIE, ID_COOKIE):
            response.delete_cookie(name)
        return response

    return router


def _loopback(url: str) -> bool:
    """Adres powrotu aplikacji: tylko http na tym samym komputerze, z numerem portu."""
    try:
        parsed = urlparse(url)
        return parsed.scheme == "http" and parsed.hostname in LOOPBACK_HOSTS and bool(parsed.port)
    except ValueError:
        return False


def _js(value: str) -> str:
    """Wartość jako literał JavaScript, bezpieczny wewnątrz <script>."""
    return json.dumps(value).replace("</", "<\\/")


def encode_flow(flow: dict[str, str]) -> str:
    """JSON w base64url – bez przecinków i spacji, które ciasteczko musiałoby cytować."""
    return base64.urlsafe_b64encode(json.dumps(flow).encode()).decode()


def decode_flow(value: str) -> dict[str, str] | None:
    try:
        return json.loads(base64.urlsafe_b64decode(value.encode()))
    except ValueError:
        return None


def _session_user(request: Request, provider: OidcProvider) -> dict | None:
    access, id_token = request.cookies.get(ACCESS_COOKIE), request.cookies.get(ID_COOKIE)
    if not access or not id_token:
        return None
    try:
        principal = provider.verify(access)
        claims = provider.decode(id_token, audience=provider.client_id)
    except InvalidToken:
        return None
    return {
        "subject": principal.subject,
        "email": claims.get("email") or claims.get("preferred_username") or "",
        "name": claims.get("name") or "",
    }


def _back_with_error(message: str) -> Response:
    response = RedirectResponse(f"/?{urlencode({'error': message})}", status_code=303)
    response.delete_cookie(FLOW_COOKIE)
    return response


def _logged_out(error: str | None) -> str:
    alert = f'<p class="alert">{html.escape(error)}</p>' if error else ""
    return f"""
      {alert}
      <h1>Trasa dopasowana do twojej ciężarówki</h1>
      <p class="muted">Wysokość, masa, długość. Ostrzeżemy, zanim wjedziesz tam, gdzie nie przejedziesz.</p>
      <a class="btn primary" href="/auth/login">Zaloguj się e-mailem</a>
      <a class="btn" href="/auth/login?register=true">Załóż konto</a>
      <p class="note">Wersja testowa: maile z kodami <strong>nie trafiają do prawdziwej poczty</strong>.
        Kod znajdziesz w lokalnej skrzynce
        <a href="http://localhost:8025" target="_blank" rel="noopener">Mailpit (localhost:8025)</a>.</p>"""


def _logged_in(user: dict, access_token: str) -> str:
    name = html.escape(user["name"] or user["email"])
    return f"""
      <p class="badge">Zalogowano</p>
      <h1>Witaj, {name}</h1>
      <dl>
        <dt>E-mail</dt><dd>{html.escape(user["email"])}</dd>
        <dt>Identyfikator</dt><dd><code>{html.escape(user["subject"])}</code></dd>
      </dl>
      <a class="btn primary" href="/planer">Planer trasy</a>
      <a class="btn" href="/docs">Dokumentacja API</a>
      <a class="btn" href="/auth/logout">Wyloguj</a>
      <details>
        <summary>Token dostępu (do „Authorize” w /docs)</summary>
        <textarea readonly rows="6" onclick="this.select()">{html.escape(access_token)}</textarea>
      </details>"""


def _page(content: str) -> str:
    return f"""<!doctype html>
<html lang="pl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>TruckMaps</title>
<style>
  :root {{ --bg:#f6f5f1; --card:#fff; --text:#1f1e1c; --muted:#5f5e5a; --border:#d3d1c7;
           --accent:#185fa5; --on-accent:#fff; --ok:#3b6d11; --warn:#ba7517; --bad:#a32d2d; }}
  @media (prefers-color-scheme: dark) {{
    :root {{ --bg:#1c1c1a; --card:#2c2c2a; --text:#f1efe8; --muted:#b4b2a9; --border:#444441;
             --accent:#85b7eb; --on-accent:#042c53; --ok:#97c459; --warn:#ef9f27; --bad:#f09595; }}
  }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; min-height:100vh; display:grid; place-items:center; padding:16px;
          background:var(--bg); color:var(--text); font:16px/1.6 system-ui, sans-serif; }}
  main {{ width:100%; max-width:380px; background:var(--card); border:1px solid var(--border);
          border-radius:20px; padding:24px; display:flex; flex-direction:column; gap:12px; }}
  .logo {{ display:flex; align-items:center; gap:10px; font-size:20px; font-weight:600; }}
  h1 {{ font-size:20px; line-height:1.35; margin:4px 0 0; }}
  .muted, .note, dt {{ color:var(--muted); }}
  .muted {{ margin:0; font-size:14px; }}
  .note {{ font-size:13px; margin:4px 0 0; text-align:center; }}
  a {{ color:var(--accent); }}
  .btn {{ display:block; text-align:center; padding:11px; border-radius:10px; text-decoration:none;
          border:1px solid var(--border); color:var(--text); font-weight:500; }}
  .btn.primary {{ background:var(--accent); border-color:var(--accent); color:var(--on-accent); }}
  .alert {{ margin:0; padding:10px 12px; border-radius:10px; border:1px solid var(--bad); color:var(--bad); font-size:14px; }}
  .badge {{ margin:0; align-self:flex-start; font-size:12px; padding:2px 10px; border-radius:999px;
            border:1px solid var(--ok); color:var(--ok); }}
  dl {{ margin:0; display:grid; grid-template-columns:auto 1fr; gap:4px 12px; font-size:14px; }}
  dd {{ margin:0; overflow-wrap:anywhere; }}
  details {{ font-size:13px; }} textarea {{ width:100%; margin-top:8px; font:12px monospace;
             background:var(--bg); color:var(--text); border:1px solid var(--border); border-radius:8px; }}
</style>
</head>
<body>
<main>
  <div class="logo">
    <svg width="28" height="28" viewBox="0 0 28 28" aria-hidden="true">
      <path d="M3 22 L10 17 L15 18" stroke="var(--ok)" stroke-width="3.5" fill="none" stroke-linecap="round"/>
      <path d="M15 18 L19 11" stroke="var(--warn)" stroke-width="3.5" fill="none" stroke-linecap="round"/>
      <path d="M19 11 L25 5" stroke="var(--bad)" stroke-width="3.5" fill="none" stroke-linecap="round"/>
    </svg>
    TruckMaps
  </div>
  {content}
</main>
</body>
</html>"""
