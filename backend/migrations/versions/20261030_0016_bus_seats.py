"""Autobusy: miejsca siedzące i stojące

Revision ID: 0016
Revises: 0015
"""

import sqlalchemy as sa
from alembic import op

revision = "0016"
down_revision = "0015"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("vehicle_profiles", sa.Column("seats", sa.Integer()))
    op.add_column("vehicle_profiles", sa.Column("standing_places", sa.Integer()))


def downgrade() -> None:
    op.drop_column("vehicle_profiles", "standing_places")
    op.drop_column("vehicle_profiles", "seats")
