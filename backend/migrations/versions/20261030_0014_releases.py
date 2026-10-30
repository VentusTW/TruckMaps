"""Wydania aplikacji, modułów i danych (sprawdzanie aktualizacji)

Revision ID: 0014
Revises: 0013
"""

import sqlalchemy as sa
from alembic import op

revision = "0014"
down_revision = "0013"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "releases",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("kind", sa.String(10), nullable=False),
        sa.Column("name", sa.String(64), nullable=False),
        sa.Column("platform", sa.String(10), nullable=False),
        sa.Column("version", sa.String(30), nullable=False),
        sa.Column("url", sa.String(500), nullable=False),
        sa.Column("size_bytes", sa.Integer(), nullable=False),
        sa.Column("sha256", sa.String(64), nullable=False),
        sa.Column("notes", sa.JSON(), nullable=False),
        sa.Column("rollout", sa.Integer(), nullable=False),
        sa.Column("status", sa.String(10), nullable=False),
        sa.Column("published_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("kind", "name", "platform", "version"),
    )


def downgrade() -> None:
    op.drop_table("releases")
