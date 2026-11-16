from fastapi.testclient import TestClient

from app.main import create_app

client = TestClient(create_app(greeting="tere", version="abc1234"))


def test_root():
    r = client.get("/")
    assert r.status_code == 200
    body = r.json()
    assert body["message"] == "tere"
    assert body["version"] == "abc1234"
    assert body["hostname"]


def test_healthz():
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_version():
    assert client.get("/version").json() == {"version": "abc1234"}


def test_unknown_route_and_method():
    assert client.get("/nope").status_code == 404
    assert client.post("/").status_code == 405


def test_defaults_from_environment(monkeypatch):
    monkeypatch.setenv("GREETING", "hei")
    monkeypatch.delenv("APP_VERSION", raising=False)
    body = TestClient(create_app()).get("/").json()
    assert body["message"] == "hei"
    assert body["version"] == "dev"
