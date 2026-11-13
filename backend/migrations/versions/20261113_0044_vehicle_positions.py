"""Centrala & Live Map: ostatnia pozycja pojazdu firmy z aplikacji kierowcy

Revision ID: 0044
Revises: 0043
"""

import sqlalchemy as sa
from alembic import op

revision = "0044"
down_revision = "0043"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "vehicle_positions",
        sa.Column("vehicle_id", sa.String(36), primary_key=True),
        sa.Column("company_id", sa.String(36), nullable=False, index=True),
        sa.Column("subject", sa.String(255), nullable=False),
        sa.Column("lat", sa.Float(), nullable=False),
        sa.Column("lon", sa.Float(), nullable=False),
        sa.Column("speed_kmh", sa.Float(), nullable=True),
        sa.Column("heading", sa.Float(), nullable=True),
        sa.Column("destination", sa.String(200), nullable=True),
        sa.Column("remaining_km", sa.Float(), nullable=True),
        sa.Column("eta", sa.DateTime(timezone=True), nullable=True),
        sa.Column("driving", sa.Boolean(), nullable=False),
        sa.Column("at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("vehicle_positions")
