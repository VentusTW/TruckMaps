"""Masa własna pojazdu (pusty) – zamiast pytania o masę rzeczywistą

Revision ID: 0020
Revises: 0019
"""

import sqlalchemy as sa
from alembic import op

revision = "0020"
down_revision = "0019"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("vehicle_profiles", sa.Column("tare_t", sa.Float()))


def downgrade() -> None:
    op.drop_column("vehicle_profiles", "tare_t")
