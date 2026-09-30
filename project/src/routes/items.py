from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from src.db.models import Items
from src.db.session import get_session
from src.models.item import Item, ItemCreate

router = APIRouter(prefix="/items", tags=["items"])

_CONFLICT_DETAIL = "An item with this name already exists"


@router.post(
    "",
    status_code=201,
    response_model=Item,
    responses={409: {"description": _CONFLICT_DETAIL}},
)
async def create_item(
    payload: ItemCreate,
    session: Annotated[AsyncSession, Depends(get_session)],
) -> Item:
    item = Items(**payload.model_dump())
    session.add(item)
    try:
        await session.commit()
    except IntegrityError as err:
        await session.rollback()
        raise HTTPException(status_code=409, detail=_CONFLICT_DETAIL) from err
    await session.refresh(item)
    return Item.model_validate(item)
