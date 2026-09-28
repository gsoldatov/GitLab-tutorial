import sys
from pathlib import Path
from typing import AsyncIterator, Iterator
from uuid import uuid4

import psycopg
import pytest
from alembic import command
from alembic.config import Config as AlembicConfig
from httpx import ASGITransport, AsyncClient
from psycopg import sql
from psycopg.rows import dict_row

_project_root = Path(__file__).resolve().parents[1]
if str(_project_root) not in sys.path:
    sys.path.insert(0, str(_project_root))

from src.app import create_app
from src.config import get_config
from src.db.models import Base
from src.db.scripts.app_db import DBManager
from src.models.config import Config
from tests.utils.data_generator import DataGenerator
from tests.utils.db_operations import DBOperations


# ── Module fixtures ────────────────────────────────────────────────────────────
@pytest.fixture(scope="module")
def test_uuid() -> str:
    return uuid4().hex


@pytest.fixture(scope="module")
def test_config(test_uuid: str) -> Config:
    config = get_config()
    # every module gets its own role and database, so modules neither see
    # each other's data nor touch the dev setup; distinct role names also
    # keep parallel workers from racing on CREATE USER
    config.db.app_username += f"_test_{test_uuid}"
    config.db.app_database += f"_test_{test_uuid}"
    return config


@pytest.fixture(scope="module")
def test_db(test_config: Config) -> Iterator[psycopg.Connection]:
    """Creates the test role and database and returns an autocommit connection."""
    with DBManager(test_config) as db_manager:
        db_manager.create_user()
        db_manager.create_db(test_config.db.app_database)

        test_conn = None
        try:
            test_conn = psycopg.connect(
                test_config.db.app_url,
                autocommit=True,
                row_factory=dict_row,
            )
            yield test_conn
        finally:
            if test_conn is not None:
                test_conn.close()
            # the role owns the database, so it must go after the database
            db_manager.delete_db(test_config.db.app_database)
            db_manager.delete_user()


@pytest.fixture(scope="module")
def test_db_migrations(
    test_db: psycopg.Connection,
    test_config: Config,
) -> Iterator[None]:
    """Applies migrations to the test database."""
    alembic_dir = _project_root / "src" / "db" / "alembic"
    alembic_cfg = AlembicConfig(str(alembic_dir / "alembic.ini"))
    alembic_cfg.set_main_option("script_location", str(alembic_dir))
    alembic_cfg.attributes["custom_config"] = test_config

    command.upgrade(alembic_cfg, "head")
    yield


# ── Test case fixtures ─────────────────────────────────────────────────────────
def _truncate_statement() -> sql.Composed:
    """Builds a TRUNCATE covering every table on the ORM metadata.

    Alembic's own version table is not part of the metadata, so the
    applied revision survives a truncation.
    """
    tables = sql.SQL(", ").join(
        sql.Identifier(table.name) for table in Base.metadata.sorted_tables
    )
    return sql.SQL("TRUNCATE TABLE {} RESTART IDENTITY CASCADE").format(tables)


@pytest.fixture
def clean_db(
    test_db: psycopg.Connection,
    test_db_migrations,
) -> Iterator[psycopg.Connection]:
    """Truncates every ORM table before and after each test.

    Depends on migrations so that the schema exists even in tests
    that never touch the app client. Truncating on setup as well as
    teardown keeps tests isolated from earlier tests on the same
    worker that did not request this fixture.
    """
    test_db.execute(_truncate_statement())
    try:
        yield test_db
    finally:
        test_db.execute(_truncate_statement())


@pytest.fixture
async def test_client(
    test_config: Config,
    test_db_migrations,
) -> AsyncIterator[AsyncClient]:
    app = create_app(test_config)
    async with (
        app.router.lifespan_context(app),
        AsyncClient(
            transport=ASGITransport(app=app),
            base_url="http://test",
        ) as client,
    ):
        yield client


@pytest.fixture
def db_operations(clean_db: psycopg.Connection) -> DBOperations:
    return DBOperations(clean_db)


@pytest.fixture
def data_generator() -> DataGenerator:
    return DataGenerator()
