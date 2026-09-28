from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from src.models.config import Config
from src.routes import setup_routes


@asynccontextmanager
async def _lifespan(app: FastAPI, config: Config) -> AsyncIterator[None]:
    engine = create_async_engine(config.db.app_sa_url)
    app.state.engine = engine
    app.state.session_factory = async_sessionmaker(engine, expire_on_commit=False)
    try:
        yield
    finally:
        await engine.dispose()


def create_app(config: Config, **kwargs: Any) -> FastAPI:
    app = FastAPI(**kwargs)
    app.state.config = config

    app.router.lifespan_context = lambda app: _lifespan(app, config)

    setup_routes(app)

    return app
