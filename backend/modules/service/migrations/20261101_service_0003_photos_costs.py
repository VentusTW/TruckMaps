"""Moduł Serwis: zdjęcia zgłoszeń i protokołów, waluta cen części

Revision ID: service_0003
Revises: service_0002
"""

import sqlalchemy as sa
from alembic import op

revision = "service_0003"
down_revision = "service_0002"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("service_orders", sa.Column("currency", sa.String(3)))
    op.create_table(
        "service_photos",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("order_id", sa.String(36), nullable=False, index=True),
        sa.Column("stage", sa.String(10), nullable=False),
        sa.Column("content_type", sa.String(20), nullable=False),
        sa.Column("data", sa.LargeBinary(), nullable=False),
        sa.Column("added_by", sa.String(255), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("service_photos")
    op.drop_column("service_orders", "currency")
