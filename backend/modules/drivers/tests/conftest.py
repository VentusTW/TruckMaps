"""Syntetyczne pliki .DDD do testów (karta kierowcy G1/G2, tachograf pojazdu G1/G2)."""

from datetime import UTC, datetime

import pytest

ACT = {"rest": 0, "available": 1, "work": 2, "driving": 3}


def _ts(moment: datetime) -> bytes:
    return int(moment.timestamp()).to_bytes(4, "big")


def _name(text: str, size: int = 36) -> bytes:
    return bytes([1]) + text.encode("latin-1").ljust(size - 1, b" ")


def change(activity: str, minute: int, *, slot=0, crew=False, absent=False, known=False) -> int:
    """ActivityChangeInfo; karta wyjęta: ``known`` – wpis ręczny."""
    c = known if absent else crew
    return slot << 15 | int(c) << 14 | int(absent) << 13 | ACT[activity] << 11 | minute


class Ddd:
    CARD = "PL000012345678"

    @staticmethod
    def tlv(fid: int, appendix: int, value: bytes) -> bytes:
        return fid.to_bytes(2, "big") + bytes([appendix]) + len(value).to_bytes(2, "big") + value

    @classmethod
    def card(
        cls,
        days: dict[datetime, list[int]],
        *,
        generation: int = 1,
        number: str | None = None,
        surname: str = "Kowalski",
        first: str = "Jan",
        places: list[tuple[datetime, int, int]] = (),
        wrap: bool = True,
    ) -> bytes:
        """Plik karty: dni (północ UTC → zmiany aktywności), miejsca (czas, rodzaj, licznik)."""
        number = (number or cls.CARD + "00")[:16].ljust(16)
        ident = (
            bytes([0x28]) + number.encode() + _name("PWPW")
            + _ts(datetime(2022, 1, 1, tzinfo=UTC)) * 2 + _ts(datetime(2027, 1, 1, tzinfo=UTC))
            + _name(surname) + _name(first) + bytes.fromhex("19800315") + b"pl"
        )  # fmt: skip
        records = []
        previous = 0
        for day, words in sorted(days.items()):
            body = b"".join(w.to_bytes(2, "big") for w in words)
            length = 12 + len(body)
            records.append(
                previous.to_bytes(2, "big") + length.to_bytes(2, "big") + _ts(day)
                + b"\x00\x01" + (100).to_bytes(2, "big") + body
            )  # fmt: skip
            previous = length
        total = sum(len(r) for r in records)
        size = total + 20
        buffer = bytearray(size)
        start = size - 15 if wrap else 0  # pierwszy rekord przechodzi przez koniec bufora
        pos = start
        offsets = []
        for record in records:
            offsets.append(pos)
            for i, byte in enumerate(record):
                buffer[(pos + i) % size] = byte
            pos = (pos + len(record)) % size
        activity = offsets[0].to_bytes(2, "big") + offsets[-1].to_bytes(2, "big") + bytes(buffer)
        data_tag = 2 if generation == 2 else 0
        place_bytes = bytearray(len(places).to_bytes(2 if generation == 2 else 1, "big"))
        for at, kind, odometer in places:
            item = _ts(at) + bytes([kind, 0x28, 0]) + odometer.to_bytes(3, "big")
            if generation == 2:
                item += _ts(at) + b"\x01" + (52135).to_bytes(3, "big") + (21006).to_bytes(3, "big")
            place_bytes += item
        return b"".join(
            [
                cls.tlv(0x0002, data_tag, bytes(25)),
                cls.tlv(0x0520, data_tag, ident),
                cls.tlv(0x0520, data_tag + 1, bytes(128)),
                cls.tlv(0x050E, data_tag, _ts(datetime(2026, 11, 14, 8, tzinfo=UTC))),
                cls.tlv(0x0504, data_tag, activity),
                cls.tlv(0x0506, data_tag, bytes(place_bytes)),
            ]
        )

    @staticmethod
    def _iw(
        number: str, name: tuple[str, str], slot: int, inserted, withdrawn, gen2: bool
    ) -> bytes:
        card = bytes([1, 0x28]) + number[:16].ljust(16).encode() + (b"\x02" if gen2 else b"")
        record = (
            _name(name[0]) + _name(name[1]) + card + _ts(datetime(2027, 1, 1, tzinfo=UTC))
            + _ts(inserted) + bytes(3) + bytes([slot])
            + (_ts(withdrawn) if withdrawn else bytes(4)) + bytes(3)
            + bytes(20 if gen2 else 19) + b"\x00"
        )  # fmt: skip
        assert len(record) == (131 if gen2 else 129)
        return record

    @classmethod
    def vu1(cls, day: datetime, words: list[int], plate: str = "WX 12345") -> bytes:
        overview = (
            b"\x76\x01" + bytes(388) + b"WMA06XZZ0NP123456" + b"\x28" + _name(plate, 14)
            + _ts(day.replace(hour=23)) + _ts(day) + _ts(day.replace(hour=23)) + b"\x00"
            + bytes(58) + b"\x00" + b"\x00" + bytes(128)
        )  # fmt: skip
        iw = cls._iw(cls.CARD + "00", ("Kowalski", "Jan"), 0, day, None, gen2=False)
        place = bytes([1, 0x28]) + (cls.CARD + "00").encode() + _ts(day.replace(hour=6))
        place += bytes([0, 0x28, 0]) + (1000).to_bytes(3, "big")
        activities = (
            b"\x76\x02" + _ts(day) + bytes(3) + (1).to_bytes(2, "big") + iw
            + len(words).to_bytes(2, "big") + b"".join(w.to_bytes(2, "big") for w in words)
            + b"\x01" + place + (0).to_bytes(2, "big") + bytes(128)
        )  # fmt: skip
        return overview + activities + b"\x76\x03" + bytes(50)

    @classmethod
    def vu2(cls, day: datetime, words: list[int], plate: str = "WX 12345") -> bytes:
        def array(kind: int, records: list[bytes], size: int) -> bytes:
            return (
                bytes([kind])
                + size.to_bytes(2, "big")
                + len(records).to_bytes(2, "big")
                + b"".join(records)
            )

        overview = b"\x76\x21" + b"".join(
            [
                array(0x0A, [b"WMA06XZZ0NP123456"], 17),
                array(0x0B, [_name(plate, 14)], 14),
                array(0x03, [_ts(day.replace(hour=23))], 4),
                array(0x13, [_ts(day) + _ts(day.replace(hour=23))], 8),
                array(0x08, [bytes(64)], 64),
            ]
        )
        iw = cls._iw("PL000099999900", ("Nowak", "Adam"), 1, day, day.replace(hour=20), gen2=True)
        activities = b"\x76\x22" + b"".join(
            [
                array(0x06, [_ts(day)], 4),
                array(0x05, [bytes(3)], 3),
                array(0x0D, [iw], 131),
                array(0x01, [w.to_bytes(2, "big") for w in words], 2),
                array(0x1C, [], 40),
                array(0x08, [bytes(64)], 64),
            ]
        )
        events = b"\x76\x23" + array(0x15, [], 10) + array(0x08, [bytes(64)], 64)
        return overview + activities + events


@pytest.fixture
def ddd() -> type[Ddd]:
    return Ddd
