import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app


@pytest.fixture
def settings() -> Settings:
    return Settings(
        port=8080,
        log_level="INFO",
        environment="test",
        version="9.9.9",
        fault_injection=False,
    )


@pytest.fixture
def client(settings: Settings) -> TestClient:
    # raise_server_exceptions=False so the 500 handler is exercised like a real server would
    return TestClient(create_app(settings), raise_server_exceptions=False)
