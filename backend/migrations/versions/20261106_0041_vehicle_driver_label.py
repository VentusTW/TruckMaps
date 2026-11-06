"""Pojazd: nazwa kierowcy z kartoteki (także bez konta)

Revision ID: 0041
Revises: 0040
"""

import sqlalchemy as sa
from alembic import op

revision = "0041"
down_revision = "0040"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("vehicle_profiles", sa.Column("assigned_driver_label", sa.String(200)))


def downgrade() -> None:
    op.drop_column("vehicle_profiles", "assigned_driver_label")
