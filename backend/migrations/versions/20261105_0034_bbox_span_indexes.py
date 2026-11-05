"""Indeksy na wysokości prostokątów (max_lat - min_lat) – szybkie zapytania wzdłuż trasy

Zapytanie o obiekty przy trasie dostaje dolną granicę ``min_lat`` (indeks ``*_bbox`` czyta
tylko pas wokół trasy), a rzadkie obiekty wyższe niż 0,05° znajduje ten indeks. Daje też
planiście statystyki wyrażenia – bez nich wybiera pełny skan tabeli.

Revision ID: 0034
Revises: 0033
"""

import sqlalchemy as sa
from alembic import op

revision = "0034"
down_revision = "0033"
branch_labels = None
depends_on = None

SPAN = sa.text("(max_lat - min_lat)")


def upgrade() -> None:
    op.create_index("ix_road_restrictions_span", "road_restrictions", [SPAN])
    op.create_index("ix_road_points_span", "road_points", [SPAN])


def downgrade() -> None:
    op.drop_index("ix_road_points_span", "road_points")
    op.drop_index("ix_road_restrictions_span", "road_restrictions")
