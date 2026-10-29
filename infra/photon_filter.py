"""Wybiera z zrzutu Photon (.jsonl.zst) tylko podane kraje i zapisuje mniejszy zrzut.

Zrzut Europy ma po rozpakowaniu ~170 GB, a Photon wczytuje go powoli (jeden wątek,
dane przez granicę Windows / kontener). Python przegląda go w kilka minut: każdy
wiersz "Place" ma jedno pole "country_code", a wiersze nagłówka (NominatimDumpFile,
CountryInfo) przechodzą bez zmian.

Użycie: python photon_filter.py ZRZUT.jsonl.zst WYNIK.jsonl.zst pl,de,cz
"""

import io
import re
import sys
import time

import zstandard

COUNTRY = re.compile(rb'"country_code":"([a-z]{2})"')
PLACE = b'{"type":"Place"'


def main() -> None:
    source_path, target_path, countries = sys.argv[1:4]
    wanted = {code.strip().encode() for code in countries.lower().split(",") if code.strip()}
    started, last, kept, total = time.monotonic(), 0.0, 0, 0
    with open(source_path, "rb") as source, open(target_path, "wb") as target:
        size = source.seek(0, io.SEEK_END)
        source.seek(0)
        reader = io.BufferedReader(
            zstandard.ZstdDecompressor().stream_reader(source, read_size=1 << 24),
            buffer_size=1 << 24,
        )
        compressor = zstandard.ZstdCompressor(level=3, threads=-1)
        with compressor.stream_writer(target, closefd=False) as writer:
            for line in reader:
                total += 1
                if line.lstrip().startswith(PLACE):
                    match = COUNTRY.search(line)
                    if match is None or match.group(1) not in wanted:
                        continue
                writer.write(line)
                kept += 1
                if time.monotonic() - last > 60:
                    last = time.monotonic()
                    print(
                        f"[postęp] {source.tell() / size:.0%} zrzutu, wybrano {kept:,} obiektów",
                        flush=True,
                    )
    minutes = (time.monotonic() - started) / 60
    print(f"Wybrano {kept:,} z {total:,} wierszy ({countries}) w {minutes:.0f} min")


if __name__ == "__main__":
    main()
