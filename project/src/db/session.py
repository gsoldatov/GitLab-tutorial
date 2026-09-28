from collections.abc import AsyncIterator

from fastapi import Request
from sqlalchemy.ext.asyncio import AsyncSession


async def get_session(request: Request) -> AsyncIterator[AsyncSession]:
    """Yields a database session bound to the current request.

    The session comes from the factory the lifespan put on app.state.
    Committing or rolling back is left to the route handler.
    """
    async with request.app.state.session_factory() as session:
        yield session
