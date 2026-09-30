import psycopg

from src.models.item import Item, ItemCreate


class ItemsDBOperations:
    """Raw SQL for items (sync, autocommit)."""

    _RETURNING = "id, name, item_description, created_at"

    def __init__(self, conn: psycopg.Connection) -> None:
        self._conn = conn

    def insert(self, data: ItemCreate) -> Item:
        row = self._conn.execute(
            "INSERT INTO items (name, item_description) "
            "VALUES (%(name)s, %(item_description)s) "
            f"RETURNING {self._RETURNING}",
            data.model_dump(),
        ).fetchone()
        return Item(**row)

    def by_id(self, item_id: int) -> Item | None:
        row = self._conn.execute(
            f"SELECT {self._RETURNING} FROM items WHERE id = %(id)s",
            {"id": item_id},
        ).fetchone()
        return Item(**row) if row is not None else None

    def count(self) -> int:
        row = self._conn.execute("SELECT count(*) FROM items").fetchone()
        return row["count"]
