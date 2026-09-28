from uuid import uuid4

from src.models.user import UserCreate


class UsersDataGenerator:
    """Generates test Pydantic models for users."""

    @staticmethod
    def user_create(
        username: str | None = None,
        email: str | None = None,
    ) -> UserCreate:
        suffix = uuid4().hex
        return UserCreate(
            username=username if username is not None else f"user_{suffix[:16]}",
            email=email if email is not None else f"{suffix}@example.com",
        )
