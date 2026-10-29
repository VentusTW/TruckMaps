import os
from logging.config import fileConfig
from pathlib import Path

from alembic import context
from sqlalchemy import create_engine

from truckmaps.core import (  # noqa: F401  (rejestrują tabele w Base.metadata)
    companies,
    parkings,
    restrictions,
    vehicles,
)
from truckmaps.core.config import load_env_file
from truckmaps.core.db import Base

config = context.config
if config.config_file_name:
    fileConfig(config.config_file_name)

load_env_file(Path.cwd() / ".env")
url = os.environ.get("TRUCKMAPS_DATABASE_URL")
if not url:
    raise SystemExit("Ustaw TRUCKMAPS_DATABASE_URL (w zmiennych środowiskowych albo w .env).")


def run_migrations() -> None:
    if context.is_offline_mode():
        context.configure(url=url, target_metadata=Base.metadata, literal_binds=True)
        with context.begin_transaction():
            context.run_migrations()
        return
    with create_engine(url).connect() as connection:
        context.configure(connection=connection, target_metadata=Base.metadata)
        with context.begin_transaction():
            context.run_migrations()


run_migrations()
