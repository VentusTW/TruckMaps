"""Firmy, członkowie, zaproszenia i pojazdy firmowe

Revision ID: 0005
Revises: 0004
"""

import sqlalchemy as sa
from alembic import op

revision = "0005"
down_revision = "0004"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "companies",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("name", sa.String(200), nullable=False),
        sa.Column("tax_id", sa.String(30)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_table(
        "company_members",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column(
            "company_id",
            sa.String(36),
            sa.ForeignKey("companies.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("subject", sa.String(255), nullable=False),
        sa.Column("display_name", sa.String(200), nullable=False),
        sa.Column("role", sa.String(20), nullable=False),
        sa.Column("joined_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("company_id", "subject"),
    )
    op.create_index("ix_company_members_subject", "company_members", ["subject"])
    op.create_table(
        "company_invites",
        sa.Column("code", sa.String(16), primary_key=True),
        sa.Column(
            "company_id",
            sa.String(36),
            sa.ForeignKey("companies.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("role", sa.String(20), nullable=False),
        sa.Column("note", sa.String(200), nullable=False),
        sa.Column("created_by", sa.String(255), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.add_column(
        "vehicle_profiles",
        sa.Column(
            "company_id",
            sa.String(36),
            sa.ForeignKey("companies.id", ondelete="SET NULL"),
            nullable=True,
        ),
    )
    op.create_index("ix_vehicle_profiles_company_id", "vehicle_profiles", ["company_id"])


def downgrade() -> None:
    op.drop_index("ix_vehicle_profiles_company_id", "vehicle_profiles")
    op.drop_column("vehicle_profiles", "company_id")
    op.drop_table("company_invites")
    op.drop_table("company_members")
    op.drop_table("companies")
