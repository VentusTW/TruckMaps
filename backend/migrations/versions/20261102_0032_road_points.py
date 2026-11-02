"""Punkty z OSM do ostrzeżeń w nawigacji: przejazdy kolejowe, fotoradary, sygnalizacja,
pomiar odcinkowy, zakazy wyprzedzania

Revision ID: 0032
Revises: 0031
"""

import sqlalchemy as sa
from alembic import op

revision = "0032"
down_revision = "0031"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "road_points",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("osm_type", sa.String(8), nullable=False),
        sa.Column("osm_id", sa.BigInteger(), nullable=False),
        sa.Column("kind", sa.String(20), nullable=False),
        sa.Column("lat", sa.Float(), nullable=False),
        sa.Column("lon", sa.Float(), nullable=False),
        sa.Column("end_lat", sa.Float()),
        sa.Column("end_lon", sa.Float()),
        sa.Column("line", sa.Text()),
        sa.Column("value", sa.Float()),
        sa.Column("min_lat", sa.Float(), nullable=False),
        sa.Column("min_lon", sa.Float(), nullable=False),
        sa.Column("max_lat", sa.Float(), nullable=False),
        sa.Column("max_lon", sa.Float(), nullable=False),
        sa.Column("source", sa.String(30), nullable=False),
        sa.Column("source_date", sa.String(20), nullable=False),
    )
    op.create_index("ix_road_points_bbox", "road_points", ["min_lat", "min_lon"])


def downgrade() -> None:
    op.drop_table("road_points")
