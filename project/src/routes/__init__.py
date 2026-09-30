from fastapi import FastAPI

from src.routes.items import router as items_router
from src.routes.root import router as root_router
from src.routes.users import router as users_router


def setup_routes(app: FastAPI) -> None:
    app.include_router(root_router)
    app.include_router(users_router)
    app.include_router(items_router)
