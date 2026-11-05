"""Moduł Dokumenty: profil firmy, szablony, wystawione dokumenty

Revision ID: documents_0001
Revises:
Depends on: 0038
"""

import sqlalchemy as sa
from alembic import op

revision = "documents_0001"
down_revision = None
branch_labels = ("documents",)
depends_on = "0038"


def upgrade() -> None:
    op.create_table(
        "document_profiles",
        sa.Column("company_id", sa.String(36), primary_key=True),
        sa.Column("data", sa.JSON(), nullable=False),
        sa.Column("logo", sa.LargeBinary()),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_table(
        "document_templates",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("company_id", sa.String(36), nullable=False, index=True),
        sa.Column("kind", sa.String(30), nullable=False),
        sa.Column("data", sa.JSON(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("company_id", "kind"),
    )
    op.create_table(
        "documents",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("company_id", sa.String(36), nullable=False, index=True),
        sa.Column("kind", sa.String(30), nullable=False),
        sa.Column("number", sa.String(40), nullable=False),
        sa.Column("vehicle_id", sa.String(36), index=True),
        sa.Column("data", sa.JSON(), nullable=False),
        sa.Column("created_by", sa.String(255), nullable=False),
        sa.Column("created_by_name", sa.String(200), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("company_id", "number"),
    )


def downgrade() -> None:
    op.drop_table("documents")
    op.drop_table("document_templates")
    op.drop_table("document_profiles")
