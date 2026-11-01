"""Ceny oleju napędowego w krajach UE (Weekly Oil Bulletin KE)

Revision ID: 0029
Revises: 0028
"""

import sqlalchemy as sa
from alembic import op

revision = "0029"
down_revision = "0028"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "fuel_prices",
        sa.Column("day", sa.Date(), primary_key=True),
        sa.Column("country", sa.String(2), primary_key=True),
        sa.Column("diesel_eur", sa.Float(), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("fuel_prices")
