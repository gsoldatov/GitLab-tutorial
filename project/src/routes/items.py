from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from src.db.models import Items
from src.db.session import get_session
from src.models.item import Item

router = APIRouter(prefix="/items", tags=["items"])

_NOT_FOUND_DETAIL = "No item with this id exists"


@router.get(
    "/{item_id}",
    response_model=Item,
    responses={404: {"description": _NOT_FOUND_DETAIL}},
)
async def read_item(
    item_id: int,
    session: Annotated[AsyncSession, Depends(get_session)],
) -> Item:
    item = await session.get(Items, item_id)
    if item is None:
        raise HTTPException(status_code=404, detail=_NOT_FOUND_DETAIL)
    return Item.model_validate(item)
