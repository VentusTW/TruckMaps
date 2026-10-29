"""Waluty: stawki z kodem waluty, kursy EBC, waluta wybrana przez użytkownika

Revision ID: 0009
Revises: 0008
"""

import sqlalchemy as sa
from alembic import op

revision = "0009"
down_revision = "0008"
branch_labels = None
depends_on = None

TABLES = ("vehicle_profiles", "companies")
RENAMED = {"cost_eur_per_km": "cost_per_km", "cost_eur_per_hour": "cost_per_hour"}


def upgrade() -> None:
    # Dotychczasowe stawki były w euro – zostają, z walutą EUR.
    for table in TABLES:
        for old, new in RENAMED.items():
            op.alter_column(table, old, new_column_name=new)
        op.add_column(
            table, sa.Column("cost_currency", sa.String(3), nullable=False, server_default="EUR")
        )
    op.create_table(
        "exchange_rates",
        sa.Column("day", sa.Date(), primary_key=True),
        sa.Column("currency", sa.String(3), primary_key=True),
        sa.Column("per_eur", sa.Float(), nullable=False),
    )
    op.create_table(
        "user_settings",
        sa.Column("subject", sa.String(255), primary_key=True),
        sa.Column("currency", sa.String(3), nullable=True),
    )


def downgrade() -> None:
    op.drop_table("user_settings")
    op.drop_table("exchange_rates")
    for table in TABLES:
        op.drop_column(table, "cost_currency")
        for old, new in RENAMED.items():
            op.alter_column(table, new, new_column_name=old)
