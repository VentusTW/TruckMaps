"""Zgłoszona usterka pojazdu (moduł Serwis)

Revision ID: 0023
Revises: 0022
"""

import sqlalchemy as sa
from alembic import op

revision = "0023"
down_revision = "0022"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "vehicle_profiles",
        sa.Column("repair_reported", sa.Boolean(), nullable=False, server_default=sa.false()),
    )


def downgrade() -> None:
    op.drop_column("vehicle_profiles", "repair_reported")
