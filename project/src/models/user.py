from datetime import datetime

from pydantic import BaseModel, ConfigDict, EmailStr, Field

_Username = Field(min_length=1, max_length=64)
_Email = Field(max_length=320)


class UserCreate(BaseModel):
    """Body of the user creation request."""

    username: str = _Username
    email: EmailStr = _Email


class User(BaseModel):
    """A user as returned by the API."""

    model_config = ConfigDict(from_attributes=True)

    id: int
    username: str
    email: EmailStr
    created_at: datetime
