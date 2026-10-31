"""Moduł Serwis: zlecenia napraw z protokołem

Revision ID: service_0001
Revises:
Depends on: 0022 (pojazd „w naprawie” w rdzeniu)
"""

import sqlalchemy as sa
from alembic import op

revision = "service_0001"
down_revision = None
branch_labels = ("service",)
depends_on = "0022"


def upgrade() -> None:
    op.create_table(
        "service_orders",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("vehicle_id", sa.String(36), nullable=False, index=True),
        sa.Column("company_id", sa.String(36), index=True),
        sa.Column("reported_by", sa.String(255), nullable=False),
        sa.Column("reporter_name", sa.String(200), nullable=False),
        sa.Column("description", sa.Text(), nullable=False),
        sa.Column("urgency", sa.String(10), nullable=False),
        sa.Column("status", sa.String(12), nullable=False),
        sa.Column("mechanic", sa.String(255)),
        sa.Column("mechanic_name", sa.String(200)),
        sa.Column("work_done", sa.Text()),
        sa.Column("parts", sa.JSON(), nullable=False),
        sa.Column("labour_hours", sa.Float()),
        sa.Column("odometer_km", sa.Integer()),
        sa.Column("notes", sa.Text()),
        sa.Column("reject_reason", sa.Text()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True)),
    )


def downgrade() -> None:
    op.drop_table("service_orders")
