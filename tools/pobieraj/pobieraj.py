"""pobieraj – pobiera duże dane TruckMaps poza sesją (mapy OSM, zrzut wyszukiwarki Photon).

Uruchamiasz w zwykłym oknie konsoli i możesz zostawić na noc:

    pobieraj.exe                    mapy i zrzut wyszukiwarki (domyślne kraje)
    pobieraj.exe mapy pl de cz      mapy OSM z Geofabrik -> infra/data/osm
    pobieraj.exe photon             zrzut Photon dla Europy -> infra/data/photon
    pobieraj.exe url ADRES [--do KATALOG]   dowolny plik
    pobieraj.exe stan               co już jest pobrane

Co robi:
- wznawia przerwane pobieranie (także po zamknięciu okna) i ponawia po zerwaniu połączenia,
- pobiera kilkoma połączeniami naraz tam, gdzie serwer zwalnia pojedyncze (Photon),
- sprawdza sumę MD5, a gdy serwer jej nie publikuje – rozmiar pliku,
- pomija pliki, których serwer nie zmienił od ostatniego pobrania,
- zapisuje wynik w infra/data/pobrane.json i dziennik w infra/data/pobieraj.log.

Pobiera przez curl.exe z Windows: w tej sieci Python i kontenery nie ufają certyfikatom HTTPS.
Potem (w katalogu projektu): infra\\build_routing.ps1, importy z data_pipeline
i infra\\photon_import.ps1.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path

CURL = "curl.exe" if os.name == "nt" else "curl"
GEOFABRIK = "https://download.geofabrik.de/europe"
PHOTON = "https://download1.graphhopper.com/public/europe"
DEFAULT_COUNTRIES = ["pl", "de", "cz", "sk", "lt"]
# Kody krajów -> nazwy plików w Geofabrik (Europa).
GEOFABRIK_NAMES = {
    "al": "albania", "at": "austria", "ba": "bosnia-herzegovina", "be": "belgium",
    "bg": "bulgaria", "by": "belarus", "ch": "switzerland", "cz": "czech-republic",
    "de": "germany", "dk": "denmark", "ee": "estonia", "es": "spain", "fi": "finland",
    "fr": "france", "gb": "great-britain", "gr": "greece", "hr": "croatia", "hu": "hungary",
    "ie": "ireland-and-northern-ireland", "it": "italy", "lt": "lithuania",
    "lu": "luxembourg", "lv": "latvia", "md": "moldova", "me": "montenegro",
    "mk": "macedonia", "nl": "netherlands", "no": "norway", "pl": "poland", "pt": "portugal",
    "ro": "romania", "rs": "serbia", "se": "sweden", "si": "slovenia", "sk": "slovakia",
    "ua": "ukraine",
}  # fmt: skip
RETRIES = 30
RETRY_DELAY_S = 15
REPORT_EVERY_S = 10


@dataclass
class Remote:
    size: int
    last_modified: str
    ranges: bool


@dataclass
class Entry:
    """Wpis w pobrane.json – dla następnej sesji i dla pomijania niezmienionych plików."""

    url: str
    path: str
    size: int
    last_modified: str
    check: str
    finished: str


# --- Serwer ----------------------------------------------------------------------------------


def curl_text(*args: str) -> str:
    result = subprocess.run([CURL, "-sSL", "--fail", *args], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or f"curl zakończył się kodem {result.returncode}")
    return result.stdout


def remote_info(url: str) -> Remote:
    return parse_headers(curl_text("-I", url))


def parse_headers(text: str) -> Remote:
    """Nagłówki ostatniej odpowiedzi (po przekierowaniach)."""
    last = re.split(r"(?m)^HTTP/", text)[-1]

    def header(name: str) -> str:
        match = re.search(rf"(?im)^{name}:\s*(.+?)\s*$", last)
        return match.group(1) if match else ""

    return Remote(
        size=int(header("content-length") or 0),
        last_modified=header("last-modified"),
        ranges=header("accept-ranges").lower() == "bytes",
    )


def remote_md5(url: str) -> str | None:
    try:
        return curl_text(f"{url}.md5").split()[0].lower()
    except (RuntimeError, IndexError):
        return None


def latest_photon_release(listing: str) -> str:
    """Najnowsze wydanie zrzutu Europy, np. "261025", z listy plików serwera."""
    releases = re.findall(r"photon-dump-europe-release-(\d{6})\.jsonl\.zst\"", listing)
    if not releases:
        raise RuntimeError("Nie znaleziono zrzutu Photon na serwerze")
    return max(releases)


# --- Pobieranie ------------------------------------------------------------------------------


def split_ranges(start: int, size: int, pieces: int) -> list[tuple[int, int]]:
    """Zakresy bajtów (włącznie) od ``start`` do końca pliku, w ``pieces`` kawałkach."""
    step = -(-(size - start) // pieces)
    return [(a, min(a + step, size) - 1) for a in range(start, size, step) if a < size]


def fetch_range(url: str, part: Path, start: int, end: int, log) -> None:
    """Bajty start..end do pliku part; po zerwaniu połączenia dociąga brakującą resztę."""
    for attempt in range(RETRIES):
        have = part.stat().st_size if part.exists() else 0
        if start + have > end:
            return
        with part.open("ab") as out:
            subprocess.run(
                [CURL, "-sSL", "--fail", "--range", f"{start + have}-{end}", url],
                stdout=out,
                stderr=subprocess.DEVNULL,
            )
        if start + part.stat().st_size <= end:
            log(f"  zerwane połączenie ({part.name}), ponowienie {attempt + 1}/{RETRIES}")
            time.sleep(RETRY_DELAY_S)
    raise RuntimeError(f"Nie udało się pobrać {part.name} po {RETRIES} próbach")


def download(url: str, target: Path, remote: Remote, connections: int, log) -> None:
    """Pobiera url do target; już pobrany początek pliku zostaje."""
    target.parent.mkdir(parents=True, exist_ok=True)
    done = target.stat().st_size if target.exists() else 0
    if done > remote.size:  # plik z innego wydania
        target.unlink()
        done = 0
    if done == remote.size:
        return
    pieces = connections if remote.ranges else 1
    ranges = split_ranges(done, remote.size, pieces) if remote.ranges else [(done, -1)]
    parts = [target.with_name(f"{target.name}.part{i}") for i in range(len(ranges))]
    if not remote.ranges:
        # Bez obsługi zakresów: jedno połączenie, curl sam wznawia (-C -).
        parts = [target]
    log(
        f"  pobieranie {(remote.size - done) / 2**20:,.0f} MB"
        f"{f' ({len(ranges)} połączeń)' if len(ranges) > 1 else ''}"
    )

    def progress() -> int:
        if not remote.ranges:
            return target.stat().st_size if target.exists() else 0
        return done + sum(p.stat().st_size for p in parts if p.exists())

    def single() -> None:
        subprocess.run(
            [CURL, "-sSL", "--fail", "-C", "-", "--retry", str(RETRIES), "--retry-all-errors",
             "--retry-delay", str(RETRY_DELAY_S), "-o", str(target), url],
            check=True,
        )  # fmt: skip

    started, first = time.monotonic(), progress()
    with ThreadPoolExecutor(len(ranges)) as pool:
        if remote.ranges:
            jobs = [
                pool.submit(fetch_range, url, part, a, b, log)
                for part, (a, b) in zip(parts, ranges, strict=True)
            ]
        else:
            jobs = [pool.submit(single)]
        while not all(job.done() for job in jobs):
            time.sleep(REPORT_EVERY_S)
            show_progress(progress(), first, remote.size, started)
        print()
        for job in jobs:
            job.result()

    if remote.ranges:
        with target.open("ab") as out:
            for part in parts:
                with part.open("rb") as source:
                    while chunk := source.read(1 << 24):
                        out.write(chunk)
                part.unlink()


def show_progress(got: int, first: int, size: int, started: float) -> None:
    elapsed = max(time.monotonic() - started, 1e-6)
    speed = (got - first) / elapsed
    left = (size - got) / speed if speed > 0 else 0
    print(
        f"\r  {got / size:6.1%}  {got / 2**30:6.2f} z {size / 2**30:.2f} GB  "
        f"{speed / 2**20:6.1f} MB/s  zostało ok. {format_duration(left)}   ",
        end="",
        flush=True,
    )


def format_duration(seconds: float) -> str:
    minutes = int(seconds // 60)
    return f"{minutes // 60} h {minutes % 60:02d} min" if minutes >= 60 else f"{minutes} min"


def md5_of(path: Path) -> str:
    digest = hashlib.md5()
    with path.open("rb") as source:
        while chunk := source.read(1 << 24):
            digest.update(chunk)
    return digest.hexdigest()


# --- Zadania ---------------------------------------------------------------------------------


class Downloader:
    def __init__(self, root: Path, connections: int) -> None:
        self.root = root
        self.data = root / "infra" / "data"
        self.connections = connections
        self.manifest_path = self.data / "pobrane.json"
        self.manifest: dict[str, dict] = (
            json.loads(self.manifest_path.read_text(encoding="utf-8"))
            if self.manifest_path.exists()
            else {}
        )

    def log(self, message: str) -> None:
        print(message, flush=True)
        self.data.mkdir(parents=True, exist_ok=True)
        with (self.data / "pobieraj.log").open("a", encoding="utf-8") as out:
            out.write(f"{datetime.now():%Y-%m-%d %H:%M:%S} {message.strip()}\n")

    def fetch(self, url: str, target: Path, connections: int | None = None) -> bool:
        """Pobiera plik, jeśli go nie ma albo serwer ma nowszy. Zwraca True, gdy pobrano."""
        inside = target.is_relative_to(self.root)
        key = target.relative_to(self.root).as_posix() if inside else str(target)
        self.log(f"{target.name}")
        remote = remote_info(url)
        known = self.manifest.get(key)
        complete = target.exists() and target.stat().st_size == remote.size
        if complete and known and known["last_modified"] == remote.last_modified:
            self.log(f"  bez zmian od {known['finished']} – pomijam")
            return False
        # Wersja serwera, z której pochodzi niedokończony plik – nie sklejamy dwóch wydań.
        version = target.with_name(f"{target.name}.wersja")
        started_from = version.read_text(encoding="utf-8") if version.exists() else None
        if known and known["last_modified"] != remote.last_modified:
            started_from = known["last_modified"]
        if started_from and started_from != remote.last_modified:
            self.log(f"  nowsza wersja na serwerze ({remote.last_modified}) – pobieram od nowa")
            for old in [target, *target.parent.glob(f"{target.name}.part*")]:
                old.unlink(missing_ok=True)
        version.parent.mkdir(parents=True, exist_ok=True)
        version.write_text(remote.last_modified, encoding="utf-8")

        download(url, target, remote, connections or self.connections, self.log)

        expected = remote_md5(url)
        if expected:
            self.log("  sprawdzanie MD5...")
            if md5_of(target) != expected:
                target.unlink()
                raise RuntimeError(f"Niezgodna suma MD5 dla {target.name} – plik usunięty")
            check = "MD5"
        else:
            if not target.exists() or target.stat().st_size != remote.size:
                raise RuntimeError(f"Niepełny plik {target.name}")
            check = "rozmiar"
        entry = Entry(
            url=url,
            path=key,
            size=remote.size,
            last_modified=remote.last_modified,
            check=check,
            finished=f"{datetime.now():%Y-%m-%d %H:%M}",
        )
        self.manifest[key] = asdict(entry)
        version.unlink()
        self.manifest_path.write_text(
            json.dumps(self.manifest, indent=2, ensure_ascii=False), encoding="utf-8"
        )
        self.log(f"  OK ({remote.size / 2**20:,.0f} MB, sprawdzono: {check})")
        return True

    def maps(self, countries: list[str]) -> None:
        for code in countries:
            name = GEOFABRIK_NAMES.get(code.lower(), code.lower())
            # Geofabrik prosi o umiar – jedno połączenie, ponowienia przy zerwaniu.
            file = f"{name}-latest.osm.pbf"
            self.fetch(f"{GEOFABRIK}/{file}", self.data / "osm" / file, connections=1)

    def photon(self, release: str) -> None:
        if release == "latest":
            release = latest_photon_release(curl_text(f"{PHOTON}/"))
        name = f"photon-dump-europe-release-{release}.jsonl.zst"
        target = self.data / "photon" / name
        self.fetch(f"{PHOTON}/{name}", target)
        # Znacznik dla infra/photon_import.ps1: plik kompletny i sprawdzony.
        target.with_name(f"{name}.ok").touch()

    def status(self) -> None:
        if not self.manifest:
            print("Nic jeszcze nie pobrano.")
        for key, entry in sorted(self.manifest.items()):
            exists = (self.root / key).exists()
            print(
                f"{key}: {entry['size'] / 2**20:,.0f} MB, pobrano {entry['finished']}, "
                f"wersja serwera {entry['last_modified']}{'' if exists else ' – PLIKU BRAK'}"
            )


def find_root(start: Path) -> Path:
    """Katalog projektu: ten, w którym jest infra/docker-compose.yml."""
    for folder in [start, *start.parents]:
        if (folder / "infra" / "docker-compose.yml").exists():
            return folder
    raise SystemExit("Nie znaleziono katalogu TruckMaps – uruchom w nim albo podaj --katalog.")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="pobieraj", description="Pobiera duże dane TruckMaps (mapy OSM, zrzut Photon)."
    )
    parser.add_argument("--katalog", type=Path, help="katalog projektu TruckMaps")
    parser.add_argument("--polaczenia", type=int, default=8, help="połączeń naraz (domyślnie 8)")
    commands = parser.add_subparsers(dest="command")
    maps = commands.add_parser("mapy", help="mapy OSM z Geofabrik")
    maps.add_argument("kraje", nargs="*", default=DEFAULT_COUNTRIES, help="np. pl de cz")
    photon = commands.add_parser("photon", help="zrzut wyszukiwarki Photon (Europa)")
    photon.add_argument("--wydanie", default="latest", help="np. 261025; domyślnie najnowsze")
    url = commands.add_parser("url", help="dowolny plik")
    url.add_argument("adres")
    url.add_argument("--do", type=Path, help="katalog docelowy (domyślnie infra/data)")
    commands.add_parser("stan", help="co już jest pobrane")
    args = parser.parse_args(argv)
    # Konsola Windows bywa w innym kodowaniu niż UTF-8 – lepiej "?" niż przerwane pobieranie.
    sys.stdout.reconfigure(errors="replace")

    if args.katalog:
        root = args.katalog.resolve()
    else:
        start = Path(sys.executable if getattr(sys, "frozen", False) else __file__).resolve()
        try:
            root = find_root(start.parent)
        except SystemExit:
            root = find_root(Path.cwd())
    downloader = Downloader(root, max(1, args.polaczenia))
    started = time.monotonic()
    try:
        if args.command == "stan":
            downloader.status()
            return
        if args.command in (None, "mapy"):
            downloader.maps(getattr(args, "kraje", DEFAULT_COUNTRIES))
        if args.command in (None, "photon"):
            downloader.photon(getattr(args, "wydanie", "latest"))
        if args.command == "url":
            folder = (args.do or downloader.data).resolve()
            downloader.fetch(args.adres, folder / args.adres.rstrip("/").rsplit("/", 1)[-1])
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        downloader.log(f"BŁĄD: {exc}")
        downloader.log("Uruchom ponownie – pobieranie wznowi się od miejsca przerwania.")
        sys.exit(1)
    except KeyboardInterrupt:
        downloader.log("Przerwano – uruchom ponownie, żeby wznowić.")
        sys.exit(130)
    downloader.log(f"Gotowe po {format_duration(time.monotonic() - started)}.")


if __name__ == "__main__":
    main()
