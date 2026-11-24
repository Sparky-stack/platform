"""Golden-path Python service (Sparky-stack/platform templates/python-service): JSON API, health and version endpoints.

Replace the routes with your own; keep /healthz (the platform's probes and smoke tests use it).
"""

import os
import socket

from fastapi import FastAPI


def create_app(greeting: str | None = None, version: str | None = None) -> FastAPI:
    greeting = greeting or os.environ.get("GREETING", "hello")
    version = version or os.environ.get("APP_VERSION", "dev")
    app = FastAPI(title="service", version=version)

    @app.get("/")
    def root() -> dict[str, str]:
        return {"message": greeting, "hostname": socket.gethostname(), "version": version}

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/version")
    def get_version() -> dict[str, str]:
        return {"version": version}

    return app


app = create_app()
