from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from src.db.models import Users
from src.db.session import get_session
from src.models.user import User, UserCreate

router = APIRouter(prefix="/users", tags=["users"])

_CONFLICT_DETAIL = "A user with this username or email already exists"


@router.post(
    "",
    status_code=201,
    response_model=User,
    responses={409: {"description": _CONFLICT_DETAIL}},
)
async def create_user(
    payload: UserCreate,
    session: Annotated[AsyncSession, Depends(get_session)],
) -> User:
    user = Users(**payload.model_dump())
    session.add(user)
    try:
        await session.commit()
    except IntegrityError as err:
        await session.rollback()
        raise HTTPException(status_code=409, detail=_CONFLICT_DETAIL) from err
    await session.refresh(user)
    return User.model_validate(user)
