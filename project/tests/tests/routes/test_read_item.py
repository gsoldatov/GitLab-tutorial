from httpx import AsyncClient

from tests.utils.data_generator import DataGenerator
from tests.utils.db_operations import DBOperations


async def test_read_item_not_found(
    test_client: AsyncClient,
    db_operations: DBOperations,
) -> None:
    assert db_operations.items.count() == 0

    response = await test_client.get("/items/1")

    assert response.status_code == 404


async def test_read_item_success(
    test_client: AsyncClient,
    db_operations: DBOperations,
    data_generator: DataGenerator,
) -> None:
    stored = db_operations.items.insert(
        data_generator.items.item_create(
            name="widget",
            item_description="a widget",
        )
    )

    response = await test_client.get(f"/items/{stored.id}")

    assert response.status_code == 200
    body = response.json()
    assert body["id"] == stored.id
    assert body["name"] == "widget"
    assert body["item_description"] == "a widget"


async def test_read_item_without_description(
    test_client: AsyncClient,
    db_operations: DBOperations,
    data_generator: DataGenerator,
) -> None:
    stored = db_operations.items.insert(
        data_generator.items.item_create(name="bare")
    )

    response = await test_client.get(f"/items/{stored.id}")

    assert response.status_code == 200
    assert response.json()["item_description"] is None


async def test_read_item_with_other_rows_present(
    test_client: AsyncClient,
    db_operations: DBOperations,
    data_generator: DataGenerator,
) -> None:
    db_operations.items.insert(data_generator.items.item_create(name="first"))
    stored = db_operations.items.insert(
        data_generator.items.item_create(name="second")
    )

    response = await test_client.get(f"/items/{stored.id}")

    assert response.status_code == 200
    assert response.json()["name"] == "second"
