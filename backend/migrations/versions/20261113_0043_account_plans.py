"""Plany kont i ich limity, licznik tras w miesiącu

Revision ID: 0043
Revises: 0042
"""

import sqlalchemy as sa
from alembic import op

revision = "0043"
down_revision = "0042"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "account_plans",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("subject", sa.String(255), nullable=True, unique=True),
        sa.Column("company_id", sa.String(36), nullable=True, unique=True),
        sa.Column("plan", sa.String(40), nullable=False),
        sa.Column("billing", sa.String(20), nullable=True),
        sa.Column("addons", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("payment_due", sa.DateTime(timezone=True), nullable=True),
        sa.Column("paid_until", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_table(
        "route_usage",
        sa.Column("subject", sa.String(255), primary_key=True),
        sa.Column("month", sa.String(7), primary_key=True),
        sa.Column("count", sa.Integer(), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("route_usage")
    op.drop_table("account_plans")
