"""Dokumenty pod krótkim linkiem (np. protokół naprawy do otwarcia w przeglądarce telefonu)

Revision ID: 0036
Revises: 0035
"""

import sqlalchemy as sa
from alembic import op

revision = "0036"
down_revision = "0035"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "shared_documents",
        sa.Column("token", sa.String(64), primary_key=True),
        sa.Column("content_type", sa.String(100), nullable=False),
        sa.Column("filename", sa.String(200), nullable=False),
        sa.Column("body", sa.LargeBinary(), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_shared_documents_expires_at", "shared_documents", ["expires_at"])


def downgrade() -> None:
    op.drop_table("shared_documents")
