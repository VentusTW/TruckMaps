"""Paliwo i spalanie pojazdu (klasa CO₂, napęd, spalanie, AdBlue, własne ceny)

Revision ID: 0024
Revises: 0023
"""

import sqlalchemy as sa
from alembic import op

revision = "0024"
down_revision = "0023"
branch_labels = None
depends_on = None

COLUMNS = {
    "co2_class": sa.Integer(),
    "fuel_type": sa.String(10),
    "consumption_empty": sa.Float(),
    "consumption_loaded": sa.Float(),
    "adblue_percent": sa.Float(),
    "fuel_price": sa.Float(),
    "adblue_price": sa.Float(),
}


def upgrade() -> None:
    for name, type_ in COLUMNS.items():
        op.add_column("vehicle_profiles", sa.Column(name, type_))


def downgrade() -> None:
    for name in reversed(COLUMNS):
        op.drop_column("vehicle_profiles", name)
