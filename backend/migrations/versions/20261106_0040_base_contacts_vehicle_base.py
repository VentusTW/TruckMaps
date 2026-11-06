"""Bazy operacyjne: dane teleadresowe; pojazd przypisany do bazy

Revision ID: 0040
Revises: 0039
"""

import sqlalchemy as sa
from alembic import op

revision = "0040"
down_revision = "0039"
branch_labels = None
depends_on = None

_TEXT = [
    ("code", 20),
    ("phone", 40),
    ("email", 200),
    ("contact_person", 200),
    ("hours", 200),
    ("note", 1000),
]


def upgrade() -> None:
    for name, length in _TEXT:
        op.add_column(
            "company_bases", sa.Column(name, sa.String(length), nullable=False, server_default="")
        )
    op.add_column("vehicle_profiles", sa.Column("base_id", sa.String(36)))
    op.create_index("ix_vehicle_profiles_base_id", "vehicle_profiles", ["base_id"])
    op.create_foreign_key(
        "fk_vehicle_profiles_base_id",
        "vehicle_profiles",
        "company_bases",
        ["base_id"],
        ["id"],
        ondelete="SET NULL",
    )


def downgrade() -> None:
    op.drop_constraint("fk_vehicle_profiles_base_id", "vehicle_profiles", type_="foreignkey")
    op.drop_index("ix_vehicle_profiles_base_id", "vehicle_profiles")
    op.drop_column("vehicle_profiles", "base_id")
    for name, _ in _TEXT:
        op.drop_column("company_bases", name)
