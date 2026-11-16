"""Entry point: `python -m app` serves the API with uvicorn on $PORT (default 8080)."""

import os

import uvicorn

from app.main import app

if __name__ == "__main__":
    # 0.0.0.0: the container's only interface is the pod network.
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8080")), log_level="info")  # noqa: S104
