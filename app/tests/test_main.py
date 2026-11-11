from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_root_returns_expected_payload():
    r = client.get("/")
    assert r.status_code == 200
    body = r.json()
    assert body["message"] == "Hello from DevOps Task!"
    assert body["status"] == "running"
    assert "version" in body


def test_health_ok():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_metrics_exposes_prometheus_format():
    client.get("/")
    r = client.get("/metrics")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/plain")
    assert "http_requests_total" in r.text
    assert "http_errors_total" in r.text
    assert "http_request_duration_seconds_bucket" in r.text


def test_unknown_route_returns_404():
    r = client.get("/does-not-exist")
    assert r.status_code == 404