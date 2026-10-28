"""DMC w profilu pojazdu

Revision ID: 0004
Revises: 0003
"""

import sqlalchemy as sa
from alembic import op

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("vehicle_profiles", sa.Column("gvw_t", sa.Float(), nullable=True))
    # Istniejące pojazdy: DMC co najmniej równa masie rzeczywistej.
    op.execute("UPDATE vehicle_profiles SET gvw_t = weight_t")
    op.alter_column("vehicle_profiles", "gvw_t", nullable=False)


def downgrade() -> None:
    op.drop_column("vehicle_profiles", "gvw_t")
