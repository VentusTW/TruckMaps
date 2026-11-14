"""Moduł Kierowcy: pliki z tachografu (.DDD), aktywności i miejsca, numer karty kierowcy

Revision ID: drivers_0002
Revises: drivers_0001
"""

import sqlalchemy as sa
from alembic import op

revision = "drivers_0002"
down_revision = "drivers_0001"
branch_labels = None
depends_on = None


def _common() -> list[sa.Column]:
    return [
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("company_id", sa.String(36), nullable=False, index=True),
        sa.Column("download_id", sa.String(36), nullable=False, index=True),
        sa.Column("source", sa.String(10), nullable=False),
        sa.Column("driver_id", sa.String(36), index=True),
        sa.Column("vehicle_id", sa.String(36), index=True),
        sa.Column("card_number", sa.String(20), nullable=False),
    ]


def upgrade() -> None:
    op.add_column("drivers", sa.Column("card_number", sa.String(20)))
    op.create_table(
        "tacho_downloads",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("company_id", sa.String(36), nullable=False, index=True),
        sa.Column("kind", sa.String(10), nullable=False),
        sa.Column("generation", sa.Integer(), nullable=False),
        sa.Column("driver_id", sa.String(36), index=True),
        sa.Column("vehicle_id", sa.String(36), index=True),
        sa.Column("name", sa.String(200), nullable=False),
        sa.Column("card_number", sa.String(20)),
        sa.Column("holder_name", sa.String(200)),
        sa.Column("vin", sa.String(17)),
        sa.Column("plate", sa.String(20)),
        sa.Column("period_start", sa.DateTime(timezone=True)),
        sa.Column("period_end", sa.DateTime(timezone=True)),
        sa.Column("activities", sa.Integer(), nullable=False),
        sa.Column("size", sa.Integer(), nullable=False),
        sa.Column("content", sa.LargeBinary(), nullable=False),
        sa.Column("by_name", sa.String(200), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_table(
        "tacho_activities",
        *_common(),
        sa.Column("start", sa.DateTime(timezone=True), nullable=False, index=True),
        sa.Column("end", sa.DateTime(timezone=True), nullable=False),
        sa.Column("activity", sa.String(12), nullable=False),
        sa.Column("slot", sa.Integer(), nullable=False),
        sa.Column("crew", sa.Boolean(), nullable=False),
        sa.Column("manual", sa.Boolean(), nullable=False),
    )
    op.create_table(
        "tacho_places",
        *_common(),
        sa.Column("at", sa.DateTime(timezone=True), nullable=False, index=True),
        sa.Column("entry", sa.String(10), nullable=False),
        sa.Column("country", sa.String(4), nullable=False),
        sa.Column("region", sa.Integer(), nullable=False),
        sa.Column("odometer", sa.Integer(), nullable=False),
        sa.Column("lat", sa.Float()),
        sa.Column("lon", sa.Float()),
    )


def downgrade() -> None:
    op.drop_table("tacho_places")
    op.drop_table("tacho_activities")
    op.drop_table("tacho_downloads")
    op.drop_column("drivers", "card_number")
