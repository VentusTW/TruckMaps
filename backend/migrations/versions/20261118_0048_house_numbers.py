"""Numery domów przy końcach trasy (OSM addr:housenumber, punkty adresowe GUGiK)

Revision ID: 0048
Revises: 0047
"""

import sqlalchemy as sa
from alembic import op

revision = "0048"
down_revision = "0047"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "house_numbers",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("lat", sa.Float(), nullable=False),
        sa.Column("lon", sa.Float(), nullable=False),
        sa.Column("number", sa.String(20), nullable=False),
        sa.Column("street", sa.String(200)),
        sa.Column("source", sa.String(10), nullable=False),
        sa.Column("source_date", sa.String(20), nullable=False),
    )
    op.create_index("ix_house_numbers_position", "house_numbers", ["lat", "lon"])


def downgrade() -> None:
    op.drop_table("house_numbers")
