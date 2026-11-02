"""Terminy pojazdu: autocasco, OC przewoźnika, dozór UDT; serwis według przebiegu;
terminy już przypomniane w skrzynce

Numer 0028 wywodzi się z 0026, bo 0027 powstaje równolegle w innej gałęzi; po scaleniu
obu – migracja łącząca (``alembic merge heads``).

Revision ID: 0028
Revises: 0026
"""

import sqlalchemy as sa
from alembic import op

revision = "0028"
down_revision = "0026"
branch_labels = None
depends_on = None

DATES = ["ac_until", "ocp_until", "udt_until"]
NUMBERS = ["odometer_km", "service_due_km"]


def upgrade() -> None:
    for name in DATES:
        op.add_column("vehicle_profiles", sa.Column(name, sa.Date()))
    for name in NUMBERS:
        op.add_column("vehicle_profiles", sa.Column(name, sa.Integer()))
    op.add_column("vehicle_profiles", sa.Column("reminders_sent", sa.JSON()))


def downgrade() -> None:
    op.drop_column("vehicle_profiles", "reminders_sent")
    for name in reversed(DATES + NUMBERS):
        op.drop_column("vehicle_profiles", name)
