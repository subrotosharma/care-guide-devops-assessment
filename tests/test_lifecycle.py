import json
import logging
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.request

import pytest
from fastapi.testclient import TestClient

from app.logging_config import configure_logging
from app.main import create_app


def test_lifespan_logs_start_and_stop(settings, caplog):
    with caplog.at_level(logging.INFO, logger="app"):
        with TestClient(create_app(settings)):
            pass
    messages = [r.getMessage() for r in caplog.records]
    assert "service starting" in messages
    assert "service stopped" in messages


def test_configure_logging_writes_json_to_stdout(capsys):
    configure_logging("INFO", "test")
    logging.getLogger("app").info("hello", extra={"path": "/x"})
    line = capsys.readouterr().out.strip().splitlines()[-1]
    parsed = json.loads(line)
    assert parsed["message"] == "hello"
    assert parsed["path"] == "/x"
    assert parsed["level"] == "info"


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def test_sigterm_shuts_down_cleanly():
    """Start the real server process, hit it, send SIGTERM, expect exit 0 and a stop log."""
    port = _free_port()
    env = {**os.environ, "APP_PORT": str(port), "LOG_LEVEL": "INFO", "APP_ENV": "test"}
    proc = subprocess.Popen(
        [sys.executable, "-m", "app"],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        deadline = time.time() + 15
        while time.time() < deadline:
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1) as r:
                    assert r.status == 200
                    break
            except OSError:
                time.sleep(0.2)
        else:
            pytest.fail("server did not become healthy in time")

        proc.send_signal(signal.SIGTERM)
        out, _ = proc.communicate(timeout=15)
    finally:
        if proc.poll() is None:
            proc.kill()

    assert proc.returncode == 0
    events = [json.loads(line) for line in out.splitlines() if line.startswith("{")]
    assert any(e["message"] == "service stopped" for e in events)
