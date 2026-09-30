from uuid import uuid4

from src.models.item import ItemCreate


class ItemsDataGenerator:
    """Generates test Pydantic models for items."""

    @staticmethod
    def item_create(
        name: str | None = None,
        item_description: str | None = None,
    ) -> ItemCreate:
        suffix = uuid4().hex
        return ItemCreate(
            name=name if name is not None else f"item_{suffix[:16]}",
            item_description=item_description,
        )
