"""Cechy pojazdu dla przedsiębiorcy (VIN, rok, klasa emisji, miejsca paletowe) i terminy

Revision ID: 0021
Revises: 0020
"""

import sqlalchemy as sa
from alembic import op

revision = "0021"
down_revision = "0020"
branch_labels = None
depends_on = None

COLUMNS = (
    ("vin", sa.String(17)),
    ("production_year", sa.Integer()),
    ("emission_class", sa.String(10)),
    ("pallet_places", sa.Integer()),
    ("last_inspection", sa.Date()),
    ("inspection_until", sa.Date()),
    ("tachograph_until", sa.Date()),
    ("insurance_until", sa.Date()),
    ("tdt_until", sa.Date()),
    ("adr_until", sa.Date()),
)


def upgrade() -> None:
    for name, kind in COLUMNS:
        op.add_column("vehicle_profiles", sa.Column(name, kind))


def downgrade() -> None:
    for name, _ in reversed(COLUMNS):
        op.drop_column("vehicle_profiles", name)
