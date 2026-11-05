"""Przejazdy: z ładunkiem / pusty, przestoje, podpięta naczepa (statystyki, krok 2)

Revision ID: 0037
Revises: 0036
"""

import sqlalchemy as sa
from alembic import op

revision = "0037"
down_revision = "0036"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("vehicle_trips", sa.Column("loaded", sa.Boolean()))
    op.add_column("vehicle_trips", sa.Column("idle_min", sa.Float()))
    op.add_column("vehicle_trips", sa.Column("trailer_id", sa.String(36)))
    op.create_index("ix_vehicle_trips_trailer_id", "vehicle_trips", ["trailer_id"])


def downgrade() -> None:
    op.drop_index("ix_vehicle_trips_trailer_id", "vehicle_trips")
    for name in ("trailer_id", "idle_min", "loaded"):
        op.drop_column("vehicle_trips", name)
