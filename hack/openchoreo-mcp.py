#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["fastmcp>=2.12,<3", "httpx>=0.27"]
# ///
"""Local stdio bridge to an OpenChoreo MCP server for headless agents (Claude Code, Hermes, Cursor, ...).

    hack/openchoreo-mcp.py http://api.openchoreo.localhost:8080/mcp          # control plane
    hack/openchoreo-mcp.py http://observer.openchoreo.localhost:11080/mcp    # observability plane

Authenticates as the Thunder OAuth client `service_mcp_client` (client_credentials, role `mcp-service`: read-only plus
workflowrun:create; docs/ai-agents.md). The client secret is read from the mgmt cluster on every token fetch
(secret platform-secrets/openchoreo, key service-mcp-client-secret), so a re-bootstrap with a new secret needs no
config change. Tokens are cached and refreshed one minute before expiry. Nothing is written to disk.

Env: OPENCHOREO_MGMT_CONTEXT (default k3d-platform-mgmt), OPENCHOREO_TOKEN_URL
(default http://thunder.openchoreo.localhost:8080/oauth2/token), OPENCHOREO_MCP_CLIENT_ID (default service_mcp_client),
OPENCHOREO_MCP_CLIENT_SECRET (skips the kubectl lookup, e.g. for a BYO cluster).
"""

import base64
import os
import subprocess
import sys
import threading
import time

import httpx
from fastmcp import Client, FastMCP
from fastmcp.client.transports import StreamableHttpTransport

CONTEXT = os.environ.get("OPENCHOREO_MGMT_CONTEXT", "k3d-platform-mgmt")
TOKEN_URL = os.environ.get("OPENCHOREO_TOKEN_URL", "http://thunder.openchoreo.localhost:8080/oauth2/token")
CLIENT_ID = os.environ.get("OPENCHOREO_MCP_CLIENT_ID", "service_mcp_client")


def client_secret() -> str:
    if os.environ.get("OPENCHOREO_MCP_CLIENT_SECRET"):
        return os.environ["OPENCHOREO_MCP_CLIENT_SECRET"]
    out = subprocess.run(
        ["kubectl", "--context", CONTEXT, "-n", "platform-secrets", "get", "secret", "openchoreo",
         "-o", "jsonpath={.data.service-mcp-client-secret}"],
        check=True, capture_output=True, text=True, timeout=30,
    ).stdout
    if not out:
        sys.exit("platform-secrets/openchoreo has no service-mcp-client-secret (run `task secrets`)")
    return base64.b64decode(out).decode()


class ClientCredentials(httpx.Auth):
    """Bearer token from Thunder's token endpoint, refreshed before expiry."""

    def __init__(self) -> None:
        self._token, self._expires, self._lock = "", 0.0, threading.Lock()

    def token(self) -> str:
        with self._lock:
            if time.time() > self._expires - 60:
                r = httpx.post(TOKEN_URL, data={"grant_type": "client_credentials"},
                               auth=(CLIENT_ID, client_secret()), timeout=30)
                r.raise_for_status()
                body = r.json()
                self._token, self._expires = body["access_token"], time.time() + int(body.get("expires_in", 3600))
            return self._token

    def auth_flow(self, request):
        request.headers["Authorization"] = f"Bearer {self.token()}"
        response = yield request
        if response.status_code == 401:  # revoked or rotated secret: fetch a fresh token once
            self._expires = 0.0
            request.headers["Authorization"] = f"Bearer {self.token()}"
            yield request


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    remote = Client(StreamableHttpTransport(sys.argv[1], auth=ClientCredentials()))
    FastMCP.as_proxy(remote, name="openchoreo").run(transport="stdio", show_banner=False)


if __name__ == "__main__":
    main()
