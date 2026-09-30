from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field

_Name = Field(min_length=1, max_length=255)
_Description = Field(default=None, max_length=1024)


class ItemCreate(BaseModel):
    """Body of the item creation request."""

    name: str = _Name
    description: str | None = _Description


class Item(BaseModel):
    """An item as returned by the API."""

    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    description: str | None
    created_at: datetime
