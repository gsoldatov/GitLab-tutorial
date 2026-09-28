import argparse
import sys
from pathlib import Path

if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

import psycopg
from psycopg import sql

from src.config import Config, get_config


class DBManager:
    """Manages the application user and database via a connection
    to the default database."""

    def __init__(self, config: Config) -> None:
        self._config = config
        self._conn = psycopg.connect(config.db.default_url, autocommit=True)

    def close(self) -> None:
        self._conn.close()

    def __enter__(self) -> "DBManager":
        return self

    def __exit__(self, *args: object) -> None:
        self.close()

    def create_user(self) -> None:
        """Creates the application user if it does not exist yet."""
        cur = self._conn.execute(
            "SELECT 1 FROM pg_roles WHERE rolname = %s",
            (self._config.db.app_username,),
        )
        exists = cur.fetchone()
        if not exists:
            self._conn.execute(
                sql.SQL("CREATE USER {} WITH PASSWORD {}").format(
                    sql.Identifier(self._config.db.app_username),
                    sql.Literal(self._config.db.app_password),
                )
            )
            print(f"  ✓ user '{self._config.db.app_username}' created")
        else:
            print(
                f"  • user '{self._config.db.app_username}' already exists, skipping"
            )

    def create_db(self, database_name: str) -> None:
        """Creates a database if it does not exist yet."""
        cur = self._conn.execute(
            "SELECT 1 FROM pg_database WHERE datname = %s",
            (database_name,),
        )
        exists = cur.fetchone()
        if not exists:
            self._conn.execute(
                sql.SQL("CREATE DATABASE {} OWNER {}").format(
                    sql.Identifier(database_name),
                    sql.Identifier(self._config.db.app_username),
                )
            )
            print(
                f"  ✓ database '{database_name}' created"
                f" (owner: '{self._config.db.app_username}')"
            )
        else:
            print(f"  • database '{database_name}' already exists, skipping")

    def delete_db(self, database_name: str) -> None:
        """Deletes a database, terminating all connections to it first."""
        self._conn.execute(
            sql.SQL(
                "SELECT pg_terminate_backend(pid) "
                "FROM pg_stat_activity "
                "WHERE datname = {} AND pid <> pg_backend_pid()"
            ).format(sql.Literal(database_name))
        )
        self._conn.execute(
            sql.SQL("DROP DATABASE IF EXISTS {}").format(
                sql.Identifier(database_name)
            )
        )

    def delete_user_databases(self) -> None:
        """Deletes all databases owned by the application user."""
        rows = self._conn.execute(
            "SELECT datname FROM pg_database "
            "WHERE datdba = (SELECT oid FROM pg_roles WHERE rolname = %s) "
            "AND NOT datistemplate",
            (self._config.db.app_username,),
        ).fetchall()

        for (db_name,) in rows:
            print(f"  • dropping database '{db_name}'…")
            self.delete_db(db_name)
            print(f"  ✓ database '{db_name}' deleted")

    def delete_user(self) -> None:
        """Deletes the application user if it exists."""
        self._conn.execute(
            sql.SQL("DROP USER IF EXISTS {}").format(
                sql.Identifier(self._config.db.app_username)
            )
        )


def _main() -> None:
    parser = argparse.ArgumentParser(
        description="Script for creating app user and database"
    )
    parser.add_argument(
        "--delete-existing",
        action="store_true",
        default=False,
        help="Delete existing database and app user beforehand",
    )
    parser.add_argument(
        "--env-file",
        type=str,
        default=None,
        help="Path to .env config file (default: .env in project root)",
    )
    args = parser.parse_args()

    config = get_config(args.env_file)

    with DBManager(config) as db:
        if args.delete_existing:
            print("Deleting database and app user…")
            db.delete_user_databases()
            db.delete_user()
            print(f"  ✓ user '{config.db.app_username}' deleted")

        print("Creating app user and database…")
        db.create_user()
        db.create_db(config.db.app_database)
        print("Done.")


if __name__ == "__main__":
    _main()
