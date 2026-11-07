"""Moduł Plan załadunku: wyposażenie użytkownika (sprzęt do mocowania)

Revision ID: load_0002
Revises: load_0001
"""

import sqlalchemy as sa
from alembic import op

revision = "load_0002"
down_revision = "load_0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "load_equipment",
        sa.Column("owner", sa.String(255), primary_key=True),
        sa.Column("data", sa.JSON(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("load_equipment")
