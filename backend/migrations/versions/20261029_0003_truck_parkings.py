"""Parkingi dla ciężarówek

Revision ID: 0003
Revises: 0002
"""

import sqlalchemy as sa
from alembic import op

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "truck_parkings",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("osm_type", sa.String(8), nullable=False),
        sa.Column("osm_id", sa.BigInteger(), nullable=False),
        sa.Column("kind", sa.String(20), nullable=False),
        sa.Column("name", sa.String(200), nullable=True),
        sa.Column("lat", sa.Float(), nullable=False),
        sa.Column("lon", sa.Float(), nullable=False),
        sa.Column("hgv_capacity", sa.Integer(), nullable=True),
        sa.Column("source", sa.String(30), nullable=False),
        sa.Column("source_date", sa.String(20), nullable=False),
    )
    op.create_index("ix_truck_parkings_lat_lon", "truck_parkings", ["lat", "lon"])


def downgrade() -> None:
    op.drop_index("ix_truck_parkings_lat_lon", table_name="truck_parkings")
    op.drop_table("truck_parkings")
