"""Obsłużone sprawy z pulpitu operacyjnego (dziennik działań dyspozytora)

Revision ID: 0039
Revises: 0038
"""

import sqlalchemy as sa
from alembic import op

revision = "0039"
down_revision = "0038"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "dashboard_alert_acks",
        sa.Column("company_id", sa.String(36), primary_key=True),
        sa.Column("alert_id", sa.String(200), primary_key=True),
        sa.Column("action", sa.String(20), nullable=False),
        sa.Column("by_subject", sa.String(255), nullable=False),
        sa.Column("by_name", sa.String(200), nullable=False),
        sa.Column("note", sa.Text()),
        sa.Column("at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("dashboard_alert_acks")
