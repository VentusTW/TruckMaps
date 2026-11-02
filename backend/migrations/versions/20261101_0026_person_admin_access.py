"""Zgoda osoby prywatnej na zmiany administratora w jej pojazdach

Revision ID: 0026
Revises: 0025
"""

import sqlalchemy as sa
from alembic import op

revision = "0026"
down_revision = "0025"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("company_access_grants") as table:
        table.alter_column("company_id", existing_type=sa.String(36), nullable=True)
        table.add_column(sa.Column("subject", sa.String(255)))
        table.create_index("ix_company_access_grants_subject", ["subject"])
    with op.batch_alter_table("admin_audit_log") as table:
        table.add_column(sa.Column("owner_subject", sa.String(255)))
        table.create_index("ix_admin_audit_log_owner_subject", ["owner_subject"])


def downgrade() -> None:
    with op.batch_alter_table("admin_audit_log") as table:
        table.drop_index("ix_admin_audit_log_owner_subject")
        table.drop_column("owner_subject")
    with op.batch_alter_table("company_access_grants") as table:
        table.drop_index("ix_company_access_grants_subject")
        table.drop_column("subject")
        table.alter_column("company_id", existing_type=sa.String(36), nullable=False)
