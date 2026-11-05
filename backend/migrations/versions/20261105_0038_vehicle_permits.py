"""Zezwolenia na przejazd przez ograniczenia (przy pojeździe albo w firmie)

Revision ID: 0038
Revises: 0037
"""

import sqlalchemy as sa
from alembic import op

revision = "0038"
down_revision = "0037"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "vehicle_permits",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("company_id", sa.String(36), index=True),
        sa.Column("owner_subject", sa.String(255), nullable=False, index=True),
        sa.Column("vehicle_ids", sa.JSON(), nullable=False),
        sa.Column("number", sa.String(100), nullable=False),
        sa.Column("issuer", sa.String(200), nullable=False),
        sa.Column("valid_from", sa.Date(), nullable=False),
        sa.Column("valid_to", sa.Date(), nullable=False),
        sa.Column("max_weight_t", sa.Float()),
        sa.Column("max_axle_t", sa.Float()),
        sa.Column("max_length_m", sa.Float()),
        sa.Column("max_width_m", sa.Float()),
        sa.Column("max_height_m", sa.Float()),
        sa.Column("hgv_ban", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("scope", sa.String(10), nullable=False),
        sa.Column("country", sa.String(2)),
        sa.Column("place", sa.String(200)),
        sa.Column("lat", sa.Float()),
        sa.Column("lon", sa.Float()),
        sa.Column("radius_km", sa.Float()),
        sa.Column("way_ids", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("vehicle_permits")
