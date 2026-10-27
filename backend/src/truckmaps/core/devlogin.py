"""Strona powitalna z testowym logowaniem (OIDC + PKCE) – do czasu aplikacji Flutter.

Przechodzi ten sam przepływ co docelowa aplikacja: przekierowanie do Zitadela,
powrót z kodem, wymiana kodu na tokeny. Tokeny trzyma w ciasteczkach httpOnly.
"""

import base64
import hashlib
import html
import json
import secrets
from urllib.parse import urlencode

import httpx
from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response

from truckmaps.core.auth import InvalidToken, OidcProvider

FLOW_COOKIE = "tm_flow"
ACCESS_COOKIE = "tm_access"
ID_COOKIE = "tm_id"
SCOPES = "openid profile email"


def build_router(provider: OidcProvider, public_url: str, http: httpx.Client | None = None):
    router = APIRouter(include_in_schema=False)
    http = http or httpx.Client(timeout=15)
    redirect_uri = f"{public_url}/auth/callback"

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

    @router.get("/auth/login")
    def login(register: bool = False) -> Response:
        state, nonce = secrets.token_urlsafe(24), secrets.token_urlsafe(24)
        verifier = secrets.token_urlsafe(64)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest())
        params = {
            "client_id": provider.client_id,
            "redirect_uri": redirect_uri,
            "response_type": "code",
            "scope": SCOPES,
            "state": state,
            "nonce": nonce,
            "code_challenge": challenge.rstrip(b"=").decode(),
            "code_challenge_method": "S256",
        }
        if register:
            params["prompt"] = "create"
        url = f"{provider.metadata['authorization_endpoint']}?{urlencode(params)}"
        response = RedirectResponse(url)
        flow = encode_flow({"state": state, "nonce": nonce, "verifier": verifier})
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

        response = RedirectResponse(f"{public_url}/", status_code=303)
        max_age = int(tokens.get("expires_in", 3600))
        for name, value in (
            (ACCESS_COOKIE, tokens["access_token"]),
            (ID_COOKIE, tokens["id_token"]),
        ):
            response.set_cookie(name, value, max_age=max_age, httponly=True, samesite="lax")
        response.delete_cookie(FLOW_COOKIE)
        return response

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
      <p class="note">Wersja testowa. Maile z kodami trafiają do skrzynki
        <a href="http://localhost:8025" target="_blank" rel="noopener">Mailpit</a>.</p>"""


def _logged_in(user: dict, access_token: str) -> str:
    name = html.escape(user["name"] or user["email"])
    return f"""
      <p class="badge">Zalogowano</p>
      <h1>Witaj, {name}</h1>
      <dl>
        <dt>E-mail</dt><dd>{html.escape(user["email"])}</dd>
        <dt>Identyfikator</dt><dd><code>{html.escape(user["subject"])}</code></dd>
      </dl>
      <a class="btn primary" href="/docs">Dokumentacja API</a>
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
