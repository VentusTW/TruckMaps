"""Rodzaje pojazdów, łączenie z naczepą / przyczepą, cysterny, pojazd w użyciu

Revision ID: 0015
Revises: 0017
"""

import sqlalchemy as sa
from alembic import op

revision = "0015"
down_revision = "0017"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Dotychczasowe pojazdy to zestawy (wymiary i masy całości).
    op.add_column(
        "vehicle_profiles",
        sa.Column("kind", sa.String(20), nullable=False, server_default="combination"),
    )
    op.add_column("vehicle_profiles", sa.Column("tank_volume_m3", sa.Float()))
    op.add_column("vehicle_profiles", sa.Column("trailer_id", sa.String(36)))
    op.add_column("vehicle_profiles", sa.Column("in_use_by", sa.String(255)))
    op.add_column("vehicle_profiles", sa.Column("in_use_until", sa.DateTime(timezone=True)))


def downgrade() -> None:
    for column in ("in_use_until", "in_use_by", "trailer_id", "tank_volume_m3", "kind"):
        op.drop_column("vehicle_profiles", column)
