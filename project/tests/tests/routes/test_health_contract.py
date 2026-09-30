from httpx import AsyncClient


async def test_health_reports_healthy(test_client: AsyncClient) -> None:
    response = await test_client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "not the status that is actually returned"}
