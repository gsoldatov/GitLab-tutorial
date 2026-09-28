import psycopg

from src.models.user import User, UserCreate


class UsersDBOperations:
    """Raw SQL for users (sync, autocommit)."""

    _RETURNING = "id, username, email, created_at"

    def __init__(self, conn: psycopg.Connection) -> None:
        self._conn = conn

    def insert(self, data: UserCreate) -> User:
        row = self._conn.execute(
            "INSERT INTO users (username, email) "
            "VALUES (%(username)s, %(email)s) "
            f"RETURNING {self._RETURNING}",
            data.model_dump(),
        ).fetchone()
        return User(**row)

    def by_username(self, username: str) -> User | None:
        row = self._conn.execute(
            f"SELECT {self._RETURNING} FROM users "
            "WHERE username = %(username)s",
            {"username": username},
        ).fetchone()
        return User(**row) if row is not None else None

    def by_email(self, email: str) -> User | None:
        row = self._conn.execute(
            f"SELECT {self._RETURNING} FROM users WHERE email = %(email)s",
            {"email": email},
        ).fetchone()
        return User(**row) if row is not None else None

    def count(self) -> int:
        row = self._conn.execute("SELECT count(*) FROM users").fetchone()
        return row["count"]
