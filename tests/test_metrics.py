import dataclasses
import re

from fastapi.testclient import TestClient

from app.main import create_app


def _sample(body: str, name: str, **labels: str) -> float:
    """Value of one exposition line, e.g. http_requests_total{...} 3.0"""
    for line in body.splitlines():
        if line.startswith("#") or not line.startswith(name):
            continue
        if all(f'{k}="{v}"' in line for k, v in labels.items()):
            return float(line.rsplit(" ", 1)[1])
    raise AssertionError(f"no sample {name}{labels} in:\n{body}")


def test_metrics_content_type_and_families(client):
    client.get("/")
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("text/plain")
    for family in (
        "# TYPE http_requests_total counter",
        "# TYPE http_request_errors_total counter",
        "# TYPE http_request_duration_seconds histogram",
    ):
        assert family in resp.text


def test_request_counter_increments(client):
    for _ in range(3):
        client.get("/")
    body = client.get("/metrics").text
    assert _sample(body, "http_requests_total", method="GET", path="/", status="200") == 3.0


def test_latency_histogram_records_observations(client):
    client.get("/")
    body = client.get("/metrics").text
    count = _sample(body, "http_request_duration_seconds_count", path="/")
    inf_bucket = _sample(body, "http_request_duration_seconds_bucket", path="/", le="+Inf")
    assert count == inf_bucket == 1.0


def test_5xx_counts_as_error(settings):
    c = TestClient(
        create_app(dataclasses.replace(settings, fault_injection=True)),
        raise_server_exceptions=False,
    )
    c.get("/fault")
    c.get("/fault")
    body = c.get("/metrics").text
    assert _sample(body, "http_request_errors_total", path="/fault") == 2.0
    assert _sample(body, "http_requests_total", path="/fault", status="500") == 2.0


def test_4xx_is_not_an_error_and_has_bounded_labels(client):
    # Many distinct bogus URLs must collapse into one series, not one each.
    for i in range(20):
        client.get(f"/scan/{i}")
    body = client.get("/metrics").text
    assert "http_request_errors_total{" not in body
    series = re.findall(r'http_requests_total\{[^}]*path="unmatched"[^}]*\}', body)
    assert len(series) == 1
    assert _sample(body, "http_requests_total", path="unmatched", status="404") == 20.0
