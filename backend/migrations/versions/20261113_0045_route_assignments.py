"""Trasy od dyspozytora wysłane kierowcom

Revision ID: 0045
Revises: 0044
"""

import sqlalchemy as sa
from alembic import op

revision = "0045"
down_revision = "0044"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "route_assignments",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("company_id", sa.String(36), nullable=False, index=True),
        sa.Column("vehicle_id", sa.String(36), nullable=False),
        sa.Column("driver_subject", sa.String(255), nullable=False, index=True),
        sa.Column("created_by", sa.String(255), nullable=False),
        sa.Column("stops", sa.JSON(), nullable=False),
        sa.Column("avoid_difficult", sa.Boolean(), nullable=False),
        sa.Column("note", sa.String(500), nullable=False),
        sa.Column("distance_km", sa.Float(), nullable=True),
        sa.Column("duration_min", sa.Float(), nullable=True),
        sa.Column("state", sa.String(20), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("route_assignments")
