"""Ograniczenia na drogach

Revision ID: 0002
Revises: 0001
"""

import sqlalchemy as sa
from alembic import op

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "road_restrictions",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("osm_type", sa.String(4), nullable=False),
        sa.Column("osm_id", sa.BigInteger(), nullable=False),
        sa.Column("kind", sa.String(20), nullable=False),
        sa.Column("value", sa.Float(), nullable=True),
        sa.Column("raw", sa.String(100), nullable=False),
        sa.Column("lat", sa.Float(), nullable=True),
        sa.Column("lon", sa.Float(), nullable=True),
        sa.Column("source", sa.String(30), nullable=False),
        sa.Column("source_date", sa.String(20), nullable=False),
    )
    op.create_index("ix_road_restrictions_osm", "road_restrictions", ["osm_type", "osm_id"])


def downgrade() -> None:
    op.drop_index("ix_road_restrictions_osm", table_name="road_restrictions")
    op.drop_table("road_restrictions")
