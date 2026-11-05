"""Moduł Kierowcy: kartoteka, historia przydziałów i zmian

Revision ID: drivers_0001
Revises:
Depends on: 0035 (przydział kierowcy do pojazdu w rdzeniu)
"""

import sqlalchemy as sa
from alembic import op

revision = "drivers_0001"
down_revision = None
branch_labels = ("drivers",)
depends_on = "0035"


def upgrade() -> None:
    op.create_table(
        "drivers",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("company_id", sa.String(36), nullable=False, index=True),
        sa.Column("subject", sa.String(255), index=True),
        sa.Column("name", sa.String(200), nullable=False),
        sa.Column("phone", sa.String(40)),
        sa.Column("email", sa.String(200)),
        sa.Column("hired_on", sa.Date()),
        sa.Column("notes", sa.Text()),
        sa.Column("license_categories", sa.JSON(), nullable=False),
        sa.Column("license_until", sa.Date()),
        sa.Column("code95_until", sa.Date()),
        sa.Column("medical_until", sa.Date()),
        sa.Column("psych_until", sa.Date()),
        sa.Column("card_until", sa.Date()),
        sa.Column("card_downloaded_on", sa.Date()),
        sa.Column("card_download_until", sa.Date()),
        sa.Column("adr_until", sa.Date()),
        sa.Column("adr_tank", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("attestation_until", sa.Date()),
        sa.Column("reminders_sent", sa.JSON()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("company_id", "subject"),
    )
    op.create_table(
        "driver_assignments",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("driver_id", sa.String(36), nullable=False, index=True),
        sa.Column("vehicle_id", sa.String(36), nullable=False, index=True),
        sa.Column("vehicle_name", sa.String(130), nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ended_at", sa.DateTime(timezone=True)),
        sa.Column("by_name", sa.String(200), nullable=False),
    )
    op.create_table(
        "driver_changes",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("driver_id", sa.String(36), nullable=False, index=True),
        sa.Column("at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("by_subject", sa.String(255), nullable=False),
        sa.Column("by_name", sa.String(200), nullable=False),
        sa.Column("action", sa.String(20), nullable=False),
        sa.Column("changes", sa.JSON(), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("driver_changes")
    op.drop_table("driver_assignments")
    op.drop_table("drivers")
