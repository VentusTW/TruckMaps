from datetime import date

import pytest

from truckmaps.core.currency import Rates, latest_rates, parse_ecb, store_rates

ECB_XML = b"""<?xml version="1.0" encoding="UTF-8"?>
<gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01"
    xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
  <gesmes:subject>Reference rates</gesmes:subject>
  <Cube>
    <Cube time="2026-10-28">
      <Cube currency="USD" rate="1.0812"/>
      <Cube currency="CZK" rate="25.31"/>
      <Cube currency="PLN" rate="4.2575"/>
    </Cube>
  </Cube>
</gesmes:Envelope>"""


def test_parse_ecb_daily_file():
    day, rates = parse_ecb(ECB_XML)

    assert day == date(2026, 10, 28)
    assert rates == {"USD": 1.0812, "CZK": 25.31, "PLN": 4.2575}


def test_parse_ecb_without_rates_fails():
    with pytest.raises(ValueError):
        parse_ecb(b"<Envelope><Cube/></Envelope>")


def test_convert_through_euro():
    rates = Rates(day=date(2026, 10, 28), per_eur={"PLN": 4.0, "CZK": 25.0})

    assert rates.convert(100, "EUR", "PLN") == 400
    assert rates.convert(400, "PLN", "EUR") == 100
    assert rates.convert(4, "PLN", "CZK") == 25
    assert rates.convert(7, "HUF", "HUF") == 7
    assert rates.convert(1, "HUF", "EUR") is None
    assert Rates().convert(1, "PLN", "EUR") is None


def test_latest_rates_are_from_newest_day(database):
    with database.session() as db:
        assert latest_rates(db) == Rates()
        assert store_rates(db, date(2026, 10, 27), {"PLN": 4.3})
        assert store_rates(db, date(2026, 10, 28), {"PLN": 4.25, "CZK": 25.3})
        assert not store_rates(db, date(2026, 10, 28), {"PLN": 9.9})  # ten dzień już jest

        assert latest_rates(db) == Rates(date(2026, 10, 28), {"PLN": 4.25, "CZK": 25.3})
