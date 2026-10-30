"""Prośby administratora o dostęp i skrzynka wiadomości w aplikacji

Revision ID: 0018
Revises: 0016
"""

import sqlalchemy as sa
from alembic import op

revision = "0018"
down_revision = "0016"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("company_access_grants") as table:
        table.add_column(sa.Column("requested_by", sa.String(255)))
        table.add_column(sa.Column("requested_at", sa.DateTime(timezone=True)))
        # Prośba czeka na zgodę: jeszcze bez udzielającego i terminu.
        table.alter_column("granted_by", existing_type=sa.String(255), nullable=True)
        table.alter_column("granted_at", existing_type=sa.DateTime(timezone=True), nullable=True)
        table.alter_column("expires_at", existing_type=sa.DateTime(timezone=True), nullable=True)
    op.create_table(
        "inbox_messages",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("recipient", sa.String(255), nullable=False, index=True),
        sa.Column("company_id", sa.String(36)),
        sa.Column("kind", sa.String(30), nullable=False),
        sa.Column("sender_name", sa.String(200), nullable=False),
        sa.Column("grant_id", sa.String(36)),
        sa.Column("data", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("read_at", sa.DateTime(timezone=True)),
    )


def downgrade() -> None:
    op.drop_table("inbox_messages")
    op.execute("DELETE FROM company_access_grants WHERE granted_at IS NULL")
    with op.batch_alter_table("company_access_grants") as table:
        table.alter_column("expires_at", existing_type=sa.DateTime(timezone=True), nullable=False)
        table.alter_column("granted_at", existing_type=sa.DateTime(timezone=True), nullable=False)
        table.alter_column("granted_by", existing_type=sa.String(255), nullable=False)
        table.drop_column("requested_at")
        table.drop_column("requested_by")
