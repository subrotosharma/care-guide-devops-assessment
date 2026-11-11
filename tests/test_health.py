def test_health_ok(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok", "environment": "test"}


def test_health_rejects_post(client):
    assert client.post("/health").status_code == 405
