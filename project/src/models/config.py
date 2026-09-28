from typing import Annotated

from pydantic import BaseModel, Field
from pydantic_settings import BaseSettings, SettingsConfigDict

_Host = Annotated[str, Field(min_length=1)]
_Port = Annotated[int, Field(gt=0, lt=65536)]
_NonEmptyString = Annotated[str, Field(min_length=1)]


class BackendConfig(BaseModel):
    """Backend API server settings."""

    host: _Host
    port: _Port


class DBConfig(BaseModel):
    """Database connection settings."""

    host: _Host
    port: _Port

    # credentials used by src/db/scripts/app_db.py to create the app role
    # and database
    default_database: _NonEmptyString
    default_username: _NonEmptyString
    default_password: _NonEmptyString

    app_database: _NonEmptyString
    app_username: _NonEmptyString
    app_password: _NonEmptyString

    @property
    def app_url(self) -> str:
        return (
            f"postgresql://"
            f"{self.app_username}:{self.app_password}"
            f"@{self.host}:{self.port}/{self.app_database}"
        )

    @property
    def app_sa_url(self) -> str:
        # one SQLAlchemy URL for both the async app engine and the
        # synchronous Alembic engine: the psycopg3 dialect serves both
        return self.app_url.replace("postgresql://", "postgresql+psycopg://")

    @property
    def default_url(self) -> str:
        return (
            f"postgresql://"
            f"{self.default_username}:{self.default_password}"
            f"@{self.host}:{self.port}/{self.default_database}"
        )


class Config(BaseSettings):
    """Application configuration loaded from the .env file."""

    model_config = SettingsConfigDict(
        env_file_encoding="utf-8",
        extra="ignore",
        env_nested_delimiter="__",
    )

    backend: BackendConfig
    db: DBConfig
