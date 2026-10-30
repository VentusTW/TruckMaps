"""Rodzaj firmy: przewoźnik towarów, spedycja, transport osób

Revision ID: 0019
Revises: 0018
"""

import sqlalchemy as sa
from alembic import op

revision = "0019"
down_revision = "0018"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Dotychczasowe firmy to przewoźnicy towarów.
    op.add_column(
        "companies",
        sa.Column("kind", sa.String(20), nullable=False, server_default="carrier"),
    )


def downgrade() -> None:
    op.drop_column("companies", "kind")
