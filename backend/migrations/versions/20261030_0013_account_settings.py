"""Ustawienia konta: imię wyświetlane, język, pierwsze logowanie

Revision ID: 0013
Revises: 0012
"""

import sqlalchemy as sa
from alembic import op

revision = "0013"
down_revision = "0012"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("user_settings", sa.Column("display_name", sa.String(200)))
    op.add_column("user_settings", sa.Column("language", sa.String(5)))
    op.add_column(
        "user_settings",
        sa.Column("onboarded", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    # Kto już należy do firmy albo coś ustawił, ma pierwsze logowanie za sobą.
    op.execute("UPDATE user_settings SET onboarded = true")
    op.execute(
        "INSERT INTO user_settings (subject, onboarded) "
        "SELECT DISTINCT subject, true FROM company_members "
        "WHERE subject NOT IN (SELECT subject FROM user_settings)"
    )


def downgrade() -> None:
    for column in ("onboarded", "language", "display_name"):
        op.drop_column("user_settings", column)
