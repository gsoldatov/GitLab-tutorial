from datetime import datetime

from httpx import AsyncClient

from tests.utils.data_generator import DataGenerator
from tests.utils.db_operations import DBOperations


# ── 422 Validation errors ──────────────────────────────────────────────────────

async def test_create_item_validation_errors(
    test_client: AsyncClient,
    db_operations: DBOperations,
) -> None:
    cases: list[dict] = [
        # description only
        {"description": "no name"},
        # empty name
        {"name": "", "description": "empty name"},
        # name longer than 255 characters
        {"name": "n" * 256, "description": "too long"},
        # description longer than 1024 characters
        {"name": "valid-name", "description": "d" * 1025},
        # non-string name
        {"name": 123, "description": "non-string name"},
    ]

    for body in cases:
        response = await test_client.post("/items", json=body)
        assert response.status_code == 422

    assert db_operations.items.count() == 0


# ── 409 Conflict ───────────────────────────────────────────────────────────────

async def test_create_item_duplicate_name(
    test_client: AsyncClient,
    db_operations: DBOperations,
    data_generator: DataGenerator,
) -> None:
    db_operations.items.insert(
        data_generator.items.item_create(name="dup-item")
    )

    response = await test_client.post(
        "/items",
        json={"name": "dup-item", "description": "another"},
    )

    assert response.status_code == 409
    assert "already exists" in response.json()["detail"]
    assert db_operations.items.count() == 1


# ── Edge cases ─────────────────────────────────────────────────────────────────

async def test_create_item_without_description(test_client: AsyncClient) -> None:
    response = await test_client.post("/items", json={"name": "no-description"})

    assert response.status_code == 201
    assert response.json()["description"] is None


async def test_create_item_name_max_length(test_client: AsyncClient) -> None:
    name = "n" * 255

    response = await test_client.post("/items", json={"name": name})

    assert response.status_code == 201
    assert response.json()["name"] == name


# ── Happy path ─────────────────────────────────────────────────────────────────

async def test_create_item_success(
    test_client: AsyncClient,
    db_operations: DBOperations,
) -> None:
    response = await test_client.post(
        "/items",
        json={"name": "widget", "description": "a widget"},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["id"] > 0
    assert body["name"] == "widget"
    assert body["description"] == "a widget"
    assert datetime.fromisoformat(body["created_at"]).tzinfo is not None


async def test_create_item_stores_row_in_db(
    test_client: AsyncClient,
    db_operations: DBOperations,
) -> None:
    response = await test_client.post(
        "/items",
        json={"name": "gadget", "description": "a gadget"},
    )
    assert response.status_code == 201

    stored = db_operations.items.by_name("gadget")
    assert stored is not None
    assert stored.id == response.json()["id"]
    assert stored.description == "a gadget"
    assert db_operations.items.count() == 1
