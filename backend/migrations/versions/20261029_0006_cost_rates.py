"""Profile kosztów: stawki €/km i €/h pojazdu i firmy

Revision ID: 0006
Revises: 0005
"""

import sqlalchemy as sa
from alembic import op

revision = "0006"
down_revision = "0005"
branch_labels = None
depends_on = None

TABLES = ("vehicle_profiles", "companies")
COLUMNS = ("cost_eur_per_km", "cost_eur_per_hour")


def upgrade() -> None:
    for table in TABLES:
        for column in COLUMNS:
            op.add_column(table, sa.Column(column, sa.Float(), nullable=True))


def downgrade() -> None:
    for table in TABLES:
        for column in COLUMNS:
            op.drop_column(table, column)
