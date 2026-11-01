from datetime import date
from pathlib import Path

from truckmaps.core import fuel_prices

BULLETIN = Path(__file__).parent / "data" / "weekly_oil_bulletin.xlsx"
PAGE = "https://energy.ec.europa.eu/data-and-analysis/weekly-oil-bulletin_en"


def test_bulletin_diesel_prices_per_country_in_euro_per_litre():
    day, prices = fuel_prices.parse_bulletin(BULLETIN.read_bytes())
    assert day == date(2026, 10, 26)
    assert len(prices) == 27
    assert (prices["PL"], prices["DE"], prices["CZ"]) == (1.7812, 2.298, 1.9495)


def test_link_to_latest_prices_is_found_on_the_bulletin_page():
    page = (
        '<a href="/document/download/abc_en?filename=Weekly%20Oil%20Bulletin%20Weekly%20prices'
        '%20with%20Taxes%20-%202026-10-26.xlsx">Prices with taxes</a>'
        '<a href="/document/download/def_en?filename=without%20Taxes.xlsx">x</a>'
    )
    link = fuel_prices.find_link(page, PAGE)
    assert link.startswith("https://energy.ec.europa.eu/document/download/abc_en?")


def test_prices_are_stored_once_per_week(database):
    with database.session() as db:
        assert fuel_prices.latest(db).day is None
        assert fuel_prices.store(db, date(2026, 10, 26), {"PL": 1.78})
        assert not fuel_prices.store(db, date(2026, 10, 26), {"PL": 1.80})
        assert fuel_prices.latest(db).diesel_eur == {"PL": 1.78}
