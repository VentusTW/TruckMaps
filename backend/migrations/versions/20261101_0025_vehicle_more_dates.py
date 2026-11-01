"""Kolejne terminy pojazdu: ATP chłodni, pobranie danych z tachografu, koniec leasingu

Revision ID: 0025
Revises: 0024
"""

import sqlalchemy as sa
from alembic import op

revision = "0025"
down_revision = "0024"
branch_labels = None
depends_on = None

COLUMNS = ["atp_until", "tachograph_download_until", "leasing_until"]


def upgrade() -> None:
    for name in COLUMNS:
        op.add_column("vehicle_profiles", sa.Column(name, sa.Date()))


def downgrade() -> None:
    for name in reversed(COLUMNS):
        op.drop_column("vehicle_profiles", name)
