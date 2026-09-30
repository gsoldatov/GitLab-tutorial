from datetime import datetime

from sqlalchemy import BigInteger, DateTime, Identity, String, UniqueConstraint
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column
from sqlalchemy.sql import func


class Base(DeclarativeBase):
    pass


class Users(Base):
    __tablename__ = "users"
    __table_args__ = (
        UniqueConstraint("username", name="uq_users_username"),
        UniqueConstraint("email", name="uq_users_email"),
    )

    id: Mapped[int] = mapped_column(
        BigInteger(),
        Identity(),
        primary_key=True,
    )
    username: Mapped[str] = mapped_column(String(64))
    email: Mapped[str] = mapped_column(String(320))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )


class Items(Base):
    __tablename__ = "items"
    __table_args__ = (UniqueConstraint("name", name="uq_items_name"),)

    id: Mapped[int] = mapped_column(
        BigInteger(),
        Identity(),
        primary_key=True,
    )
    name: Mapped[str] = mapped_column(String(255))
    description: Mapped[str | None] = mapped_column(String(1024), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
