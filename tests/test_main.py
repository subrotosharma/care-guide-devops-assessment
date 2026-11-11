import dataclasses
import json
import logging

from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app


def test_root_returns_expected_payload(client):
    resp = client.get("/")
    assert resp.status_code == 200
    assert resp.json() == {
        "message": "Hello from DevOps Task!",
        "status": "running",
        "version": "9.9.9",
    }


def test_unknown_route_is_404(client):
    assert client.get("/nope").status_code == 404


def test_fault_endpoint_absent_by_default(client):
    assert client.get("/fault").status_code == 404


def test_fault_endpoint_returns_500_when_enabled(settings):
    enabled = dataclasses.replace(settings, fault_injection=True)
    c = TestClient(create_app(enabled), raise_server_exceptions=False)
    resp = c.get("/fault")
    assert resp.status_code == 500
    assert resp.json() == {"detail": "internal server error"}


def test_request_log_is_structured(client, caplog):
    with caplog.at_level(logging.INFO, logger="app"):
        client.get("/")
    rec = next(r for r in caplog.records if r.getMessage() == "request handled")
    assert rec.path == "/"
    assert rec.status == 200
    assert rec.method == "GET"
    assert rec.duration_ms >= 0


def test_json_formatter_emits_valid_json_with_extras():
    from app.logging_config import JsonFormatter

    record = logging.LogRecord("app", logging.INFO, __file__, 1, "hello %s", ("x",), None)
    record.path = "/p"
    out = json.loads(JsonFormatter("test").format(record))
    assert out["level"] == "info"
    assert out["message"] == "hello x"
    assert out["path"] == "/p"
    assert out["env"] == "test"
    assert out["timestamp"].endswith("Z")


def test_json_formatter_includes_exception():
    from app.logging_config import JsonFormatter

    try:
        raise ValueError("boom")
    except ValueError:
        import sys

        record = logging.LogRecord("app", logging.ERROR, __file__, 1, "failed", (), sys.exc_info())
    out = json.loads(JsonFormatter().format(record))
    assert "ValueError: boom" in out["exception"]


def test_settings_defaults(monkeypatch):
    for var in ("APP_PORT", "LOG_LEVEL", "APP_ENV", "APP_VERSION", "ENABLE_FAULT_INJECTION"):
        monkeypatch.delenv(var, raising=False)
    s = Settings.from_env()
    assert (s.port, s.log_level, s.environment, s.fault_injection) == (8080, "INFO", "local", False)


def test_settings_from_env(monkeypatch):
    monkeypatch.setenv("APP_PORT", "9000")
    monkeypatch.setenv("LOG_LEVEL", "debug")
    monkeypatch.setenv("APP_ENV", "staging")
    monkeypatch.setenv("APP_VERSION", "1.2.3")
    monkeypatch.setenv("ENABLE_FAULT_INJECTION", "true")
    s = Settings.from_env()
    assert (s.port, s.log_level, s.environment, s.version, s.fault_injection) == (
        9000,
        "DEBUG",
        "staging",
        "1.2.3",
        True,
    )


def test_settings_reject_bad_port(monkeypatch):
    import pytest

    monkeypatch.setenv("APP_PORT", "abc")
    with pytest.raises(ValueError, match="APP_PORT"):
        Settings.from_env()
    monkeypatch.setenv("APP_PORT", "70000")
    with pytest.raises(ValueError, match="out of range"):
        Settings.from_env()


def test_settings_reject_bad_log_level(monkeypatch):
    import pytest

    monkeypatch.setenv("LOG_LEVEL", "LOUD")
    with pytest.raises(ValueError, match="LOG_LEVEL"):
        Settings.from_env()
