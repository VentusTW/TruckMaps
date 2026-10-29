"""Zgłoszenia od kierowców (punkty dostawy, problemy na drodze) i głosy „aktualne / nieaktualne”

Revision ID: 0011
Revises: 0010
"""

import sqlalchemy as sa
from alembic import op

revision = "0011"
down_revision = "0010"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "driver_reports",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("subject", sa.String(255), nullable=False, index=True),
        sa.Column("kind", sa.String(20), nullable=False),
        sa.Column("lat", sa.Float(), nullable=False),
        sa.Column("lon", sa.Float(), nullable=False),
        sa.Column("note", sa.String(300), nullable=False),
        sa.Column("value", sa.Float()),
        sa.Column("score", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("confirmed_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_driver_reports_lat_lon", "driver_reports", ["lat", "lon"])
    op.create_table(
        "driver_report_votes",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column(
            "report_id",
            sa.String(36),
            sa.ForeignKey("driver_reports.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("subject", sa.String(255), nullable=False),
        sa.Column("up", sa.Boolean(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("report_id", "subject"),
    )


def downgrade() -> None:
    op.drop_table("driver_report_votes")
    op.drop_index("ix_driver_reports_lat_lon", table_name="driver_reports")
    op.drop_table("driver_reports")
