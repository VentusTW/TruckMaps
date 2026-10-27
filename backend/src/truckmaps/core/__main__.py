"""Start serwera TruckMaps: ``python -m truckmaps.core`` lub ``TruckMaps-Server.exe``."""

import argparse
import os
import threading
import webbrowser

import uvicorn

from truckmaps.core.app import create_app
from truckmaps.core.version import CORE_VERSION


def main() -> None:
    parser = argparse.ArgumentParser(prog="truckmaps", description="Serwer TruckMaps")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--no-browser", action="store_true", help="nie otwieraj przeglądarki")
    args = parser.parse_args()

    # Faza 0 nie ma jeszcze kont – lokalnie każde konto ma każdy moduł.
    # Wyłączenie: TRUCKMAPS_DEV_GRANT_ALL=false.
    os.environ.setdefault("TRUCKMAPS_DEV_GRANT_ALL", "true")

    app = create_app()
    url = f"http://{args.host}:{args.port}/docs"
    print(f"TruckMaps {CORE_VERSION} – {url} (Ctrl+C kończy)")
    if not args.no_browser:
        threading.Timer(1.5, webbrowser.open, args=[url]).start()

    uvicorn.run(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
