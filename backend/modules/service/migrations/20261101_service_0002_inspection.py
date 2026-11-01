"""Moduł Serwis: przegląd techniczny w protokole (ważny do)

Revision ID: service_0002
Revises: service_0001
"""

import sqlalchemy as sa
from alembic import op

revision = "service_0002"
down_revision = "service_0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("service_orders", sa.Column("inspection_until", sa.Date()))


def downgrade() -> None:
    op.drop_column("service_orders", "inspection_until")
