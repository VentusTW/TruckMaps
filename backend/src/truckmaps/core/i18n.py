"""Teksty rdzenia w wielu językach i język zapytania z nagłówka ``Accept-Language``.

Teksty: ``locales/<język>.json``. Nowy język = nowy plik z tymi samymi kluczami
(test pilnuje, żeby każdy plik miał wszystkie klucze polskiego i te same parametry).
"""

import json
from importlib import resources

from truckmaps.sdk.i18n import Msg, language, negotiate, num, register, t, use

__all__ = ["LanguageMiddleware", "Msg", "language", "load", "num", "t", "use"]


def load() -> None:
    for file in (resources.files("truckmaps.core") / "locales").iterdir():
        if file.name.endswith(".json"):
            register(file.name.removesuffix(".json"), json.loads(file.read_text("utf-8")))


load()


class LanguageMiddleware:
    """Ustawia język zapytania i odpowiada nagłówkiem ``Content-Language``."""

    def __init__(self, app) -> None:
        self.app = app

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        header = dict(scope["headers"]).get(b"accept-language", b"").decode("latin-1")
        chosen = negotiate(header)

        async def send_with_language(message) -> None:
            if message["type"] == "http.response.start":
                message["headers"] = [
                    *message.get("headers", []),
                    (b"content-language", chosen.encode()),
                    (b"vary", b"Accept-Language"),
                ]
            await send(message)

        with use(chosen):
            await self.app(scope, receive, send_with_language)
