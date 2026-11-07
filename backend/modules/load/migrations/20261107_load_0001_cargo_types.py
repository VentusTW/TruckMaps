"""Moduł Plan załadunku: własne rodzaje towaru użytkowników

Revision ID: load_0001
Revises:
"""

import sqlalchemy as sa
from alembic import op

revision = "load_0001"
down_revision = None
branch_labels = ("load",)
depends_on = None


def upgrade() -> None:
    op.create_table(
        "load_cargo_types",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("owner", sa.String(255), nullable=False, index=True),
        sa.Column("data", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("load_cargo_types")
