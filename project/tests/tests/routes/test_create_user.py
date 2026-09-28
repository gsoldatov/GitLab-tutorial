from datetime import datetime

from httpx import AsyncClient

from tests.utils.data_generator import DataGenerator
from tests.utils.db_operations import DBOperations


# ── 422 Validation errors ──────────────────────────────────────────────────────

async def test_create_user_validation_errors(
    test_client: AsyncClient,
    db_operations: DBOperations,
) -> None:
    cases: list[dict] = [
        # email only
        {"email": "alice@example.com"},
        # username only
        {"username": "alice"},
        # malformed email
        {"username": "alice", "email": "not-an-email"},
        # empty username
        {"username": "", "email": "alice@example.com"},
        # username longer than 64 characters
        {"username": "u" * 65, "email": "alice@example.com"},
        # non-string username
        {"username": 123, "email": "alice@example.com"},
    ]

    for body in cases:
        response = await test_client.post("/users", json=body)
        assert response.status_code == 422

    assert db_operations.users.count() == 0


# ── 409 Conflict ───────────────────────────────────────────────────────────────

async def test_create_user_duplicate_username(
    test_client: AsyncClient,
    db_operations: DBOperations,
    data_generator: DataGenerator,
) -> None:
    db_operations.users.insert(
        data_generator.users.user_create(username="dup-user")
    )

    response = await test_client.post(
        "/users",
        json={"username": "dup-user", "email": "other@example.com"},
    )

    assert response.status_code == 409
    assert "already exists" in response.json()["detail"]
    assert db_operations.users.count() == 1


async def test_create_user_duplicate_email(
    test_client: AsyncClient,
    db_operations: DBOperations,
    data_generator: DataGenerator,
) -> None:
    db_operations.users.insert(
        data_generator.users.user_create(email="dup@example.com")
    )

    response = await test_client.post(
        "/users",
        json={"username": "other-user", "email": "dup@example.com"},
    )

    assert response.status_code == 409
    assert db_operations.users.count() == 1


# ── Edge cases ─────────────────────────────────────────────────────────────────

async def test_create_user_username_max_length(test_client: AsyncClient) -> None:
    username = "u" * 64

    response = await test_client.post(
        "/users",
        json={"username": username, "email": "max@example.com"},
    )

    assert response.status_code == 201
    assert response.json()["username"] == username


# ── Happy path ─────────────────────────────────────────────────────────────────

async def test_create_user_success(
    test_client: AsyncClient,
    db_operations: DBOperations,
) -> None:
    response = await test_client.post(
        "/users",
        json={"username": "alice", "email": "alice@example.com"},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["id"] > 0
    assert body["username"] == "alice"
    assert body["email"] == "alice@example.com"
    assert datetime.fromisoformat(body["created_at"]).tzinfo is not None


async def test_create_user_stores_row_in_db(
    test_client: AsyncClient,
    db_operations: DBOperations,
) -> None:
    response = await test_client.post(
        "/users",
        json={"username": "bob", "email": "bob@example.com"},
    )
    assert response.status_code == 201

    stored = db_operations.users.by_username("bob")
    assert stored is not None
    assert stored.id == response.json()["id"]
    assert stored.email == "bob@example.com"
    assert db_operations.users.count() == 1
