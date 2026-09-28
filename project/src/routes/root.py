from fastapi import APIRouter

router = APIRouter(tags=["health"])


@router.get(
    "/health",
    status_code=200,
    responses={200: {"description": "Service is healthy"}},
)
async def health() -> dict[str, str]:
    return {"status": "ok"}
