"""Ograniczenia warunkowe z OSM: dłuższy surowy tag (np. hgv:conditional=no @ (…))

Revision ID: 0010
Revises: 0009
"""

import sqlalchemy as sa
from alembic import op

revision = "0010"
down_revision = "0009"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.alter_column("road_restrictions", "raw", type_=sa.String(255), existing_type=sa.String(100))


def downgrade() -> None:
    op.execute("UPDATE road_restrictions SET raw = left(raw, 100)")
    op.alter_column("road_restrictions", "raw", type_=sa.String(100), existing_type=sa.String(255))
