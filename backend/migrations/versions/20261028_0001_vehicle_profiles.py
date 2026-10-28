"""Profile pojazdów

Revision ID: 0001
Revises:
"""

import sqlalchemy as sa
from alembic import op

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "vehicle_profiles",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("owner_subject", sa.String(255), nullable=False),
        sa.Column("name", sa.String(100), nullable=False),
        sa.Column("height_m", sa.Float(), nullable=False),
        sa.Column("width_m", sa.Float(), nullable=False),
        sa.Column("length_m", sa.Float(), nullable=False),
        sa.Column("weight_t", sa.Float(), nullable=False),
        sa.Column("axle_load_t", sa.Float(), nullable=False),
        sa.Column("axle_count", sa.Integer(), nullable=False),
        sa.Column("trailer_type", sa.String(20), nullable=False),
        sa.Column("hazmat", sa.Boolean(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_vehicle_profiles_owner_subject", "vehicle_profiles", ["owner_subject"])


def downgrade() -> None:
    op.drop_index("ix_vehicle_profiles_owner_subject", table_name="vehicle_profiles")
    op.drop_table("vehicle_profiles")
