"""Moduł Serwis: stawka za godzinę pracy w protokole

Revision ID: service_0004
Revises: service_0003
"""

import sqlalchemy as sa
from alembic import op

revision = "service_0004"
down_revision = "service_0003"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("service_orders", sa.Column("labour_rate", sa.Float()))


def downgrade() -> None:
    op.drop_column("service_orders", "labour_rate")
