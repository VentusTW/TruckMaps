"""Zgłoszone ograniczenia przypisane do drogi OSM i zapisane na stałe po kilku potwierdzeniach

Revision ID: 0027
Revises: 0026
"""

import sqlalchemy as sa
from alembic import op

revision = "0027"
down_revision = "0026"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("driver_reports", sa.Column("way_id", sa.BigInteger()))
    op.add_column("driver_reports", sa.Column("permanent_at", sa.DateTime(timezone=True)))
    op.create_index("ix_driver_reports_way_id", "driver_reports", ["way_id"])


def downgrade() -> None:
    op.drop_index("ix_driver_reports_way_id", "driver_reports")
    op.drop_column("driver_reports", "permanent_at")
    op.drop_column("driver_reports", "way_id")
