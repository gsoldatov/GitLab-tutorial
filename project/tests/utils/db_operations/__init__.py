import psycopg

from tests.utils.db_operations.items import ItemsDBOperations
from tests.utils.db_operations.users import UsersDBOperations


class DBOperations:
    """Facade over raw SQL operations with the test database."""

    def __init__(self, conn: psycopg.Connection) -> None:
        self.users = UsersDBOperations(conn)
        self.items = ItemsDBOperations(conn)
