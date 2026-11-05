"""Wymiary z dokumentów pojazdu (siodło, sworzeń, osie, rozstaw osi) i przydział kierowcy

Revision ID: 0035
Revises: 0034
"""

import sqlalchemy as sa
from alembic import op

revision = "0035"
down_revision = "0034"
branch_labels = None
depends_on = None

COLUMNS = ("fifth_wheel_m", "kingpin_m", "axles_m", "wheelbase_m")


def upgrade() -> None:
    op.add_column("vehicle_profiles", sa.Column("assigned_driver", sa.String(255)))
    for name in COLUMNS:
        op.add_column("vehicle_profiles", sa.Column(name, sa.Float()))


def downgrade() -> None:
    for name in ("assigned_driver", *COLUMNS):
        op.drop_column("vehicle_profiles", name)
