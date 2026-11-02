"""Przejazdy pojazdów (statystyki): km według GPS, czas, kierowca, szacowany koszt

Revision ID: 0031
Revises: 0030
"""

import sqlalchemy as sa
from alembic import op

revision = "0031"
down_revision = "0030"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "vehicle_trips",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column(
            "vehicle_id",
            sa.String(36),
            sa.ForeignKey("vehicle_profiles.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        sa.Column("driver", sa.String(255), nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ended_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("distance_km", sa.Float(), nullable=False),
        sa.Column("planned_km", sa.Float()),
        sa.Column("cost_amount", sa.Float()),
        sa.Column("cost_currency", sa.String(3)),
    )


def downgrade() -> None:
    op.drop_table("vehicle_trips")
