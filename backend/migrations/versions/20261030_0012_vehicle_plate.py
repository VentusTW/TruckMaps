"""Tablica rejestracyjna pojazdu

Revision ID: 0012
Revises: 0011
"""

import sqlalchemy as sa
from alembic import op

revision = "0012"
down_revision = "0011"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("vehicle_profiles", sa.Column("plate", sa.String(15)))


def downgrade() -> None:
    op.drop_column("vehicle_profiles", "plate")
