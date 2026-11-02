"""Powiadomienia e-mail: zgoda i adres w ustawieniach konta, znacznik wysłania wiadomości

Revision ID: 0030
Revises: 0029
"""

import sqlalchemy as sa
from alembic import op

revision = "0030"
down_revision = "0029"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "user_settings",
        sa.Column("email_notifications", sa.Boolean(), nullable=False, server_default="false"),
    )
    op.add_column("user_settings", sa.Column("email", sa.String(320)))
    op.add_column("inbox_messages", sa.Column("emailed_at", sa.DateTime(timezone=True)))


def downgrade() -> None:
    op.drop_column("inbox_messages", "emailed_at")
    op.drop_column("user_settings", "email")
    op.drop_column("user_settings", "email_notifications")
