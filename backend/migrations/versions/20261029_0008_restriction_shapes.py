"""Przebieg dróg z ograniczeniami (korytarz danych dla telefonu)

Revision ID: 0008
Revises: 0007
"""

import sqlalchemy as sa
from alembic import op

revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None

BBOX = ("min_lat", "min_lon", "max_lat", "max_lon")


def upgrade() -> None:
    op.add_column("road_restrictions", sa.Column("line", sa.Text(), nullable=True))
    for column in BBOX:
        op.add_column("road_restrictions", sa.Column(column, sa.Float(), nullable=True))
    # Punkty mają już położenie – prostokąt to sam punkt.
    op.execute(
        "UPDATE road_restrictions SET min_lat = lat, max_lat = lat, min_lon = lon, max_lon = lon "
        "WHERE lat IS NOT NULL"
    )
    op.create_index("ix_road_restrictions_bbox", "road_restrictions", ["min_lat", "min_lon"])


def downgrade() -> None:
    op.drop_index("ix_road_restrictions_bbox", "road_restrictions")
    for column in ("line", *BBOX):
        op.drop_column("road_restrictions", column)
