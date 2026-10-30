"""Program administracyjny: konta administratorów, dziennik działań, zgody właścicieli firm

Revision ID: 0017
Revises: 0014

Numer 0017, bo 0015–0016 są na gałęzi claude/logowanie-plany – po jej scaleniu
``down_revision`` trzeba zmienić na "0016".
"""

import sqlalchemy as sa
from alembic import op

revision = "0017"
down_revision = "0014"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "admin_accounts",
        sa.Column("subject", sa.String(255), primary_key=True),
        sa.Column("name", sa.String(200), nullable=False),
        sa.Column("role", sa.String(10), nullable=False),
        sa.Column("created_by", sa.String(255), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("disabled_at", sa.DateTime(timezone=True)),
    )
    op.create_table(
        "admin_audit_log",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("at", sa.DateTime(timezone=True), nullable=False, index=True),
        sa.Column("subject", sa.String(255), nullable=False, index=True),
        sa.Column("role", sa.String(10), nullable=False),
        sa.Column("method", sa.String(10), nullable=False),
        sa.Column("path", sa.String(500), nullable=False),
        sa.Column("query", sa.String(1000), nullable=False),
        sa.Column("status_code", sa.Integer(), nullable=False),
        sa.Column("ip", sa.String(64), nullable=False),
        sa.Column("user_agent", sa.String(300), nullable=False),
        sa.Column("action", sa.String(50), nullable=False, index=True),
        sa.Column("company_id", sa.String(36), index=True),
        sa.Column("changes", sa.JSON()),
    )
    op.create_table(
        "company_access_grants",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column(
            "company_id",
            sa.String(36),
            sa.ForeignKey("companies.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        sa.Column("scopes", sa.JSON(), nullable=False),
        sa.Column("note", sa.String(300), nullable=False),
        sa.Column("granted_by", sa.String(255), nullable=False),
        sa.Column("granted_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("revoked_by", sa.String(255)),
        sa.Column("revoked_at", sa.DateTime(timezone=True)),
    )


def downgrade() -> None:
    op.drop_table("company_access_grants")
    op.drop_table("admin_audit_log")
    op.drop_table("admin_accounts")
