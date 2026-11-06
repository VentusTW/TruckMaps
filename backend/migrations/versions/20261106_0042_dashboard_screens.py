"""Treść kart pulpitu głównego (dane, których rdzeń jeszcze nie liczy)

Revision ID: 0042
Revises: 0039
"""

import sqlalchemy as sa
from alembic import op

revision = "0042"
down_revision = "0039"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Tabela mogła powstać z `python -m truckmaps.core.dashboard_demo` – wtedy bez zmian.
    if sa.inspect(op.get_bind()).has_table("dashboard_screens"):
        return
    op.create_table(
        "dashboard_screens",
        sa.Column("company_id", sa.String(36), primary_key=True),
        sa.Column("payload", sa.JSON(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("dashboard_screens")
