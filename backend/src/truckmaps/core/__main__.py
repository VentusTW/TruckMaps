"""Start serwera TruckMaps: ``python -m truckmaps.core`` lub ``TruckMaps-Server.exe``."""

import argparse
import os
import threading
import webbrowser
from pathlib import Path

import uvicorn

from truckmaps.core.app import create_app
from truckmaps.core.config import Settings, load_env_file
from truckmaps.core.version import CORE_VERSION


def main() -> None:
    parser = argparse.ArgumentParser(prog="truckmaps", description="Serwer TruckMaps")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--no-browser", action="store_true", help="nie otwieraj przeglądarki")
    args = parser.parse_args()

    # Konfigurację logowania zapisuje tu infra/zitadel/bootstrap.py.
    load_env_file(Path.cwd() / ".env")
    # Uruchomienie lokalne: każdy ma każdy moduł, a / pokazuje testowe logowanie.
    # Wyłączenie: TRUCKMAPS_DEV_GRANT_ALL=false, TRUCKMAPS_DEV_LOGIN=false.
    os.environ.setdefault("TRUCKMAPS_DEV_GRANT_ALL", "true")
    os.environ.setdefault("TRUCKMAPS_DEV_LOGIN", "true")

    settings = Settings.from_env()
    app = create_app(settings)
    if settings.oidc_enabled and settings.dev_login_page:
        url = f"{settings.public_url}/"
    else:
        url = f"http://{args.host}:{args.port}/docs"
    print(f"TruckMaps {CORE_VERSION} – {url} (Ctrl+C kończy)")
    if not args.no_browser:
        threading.Timer(1.5, webbrowser.open, args=[url]).start()

    uvicorn.run(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
