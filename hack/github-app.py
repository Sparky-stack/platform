#!/usr/bin/env python3
"""Create and check the platform write GitHub App (docs/forking.md credentials (c)) for the Backstage scaffolder.

  hack/github-app.py manifest --org ORG                  print the App manifest (no network)
  hack/github-app.py create   --org ORG [--public-url U] serve the manifest flow on 127.0.0.1:8765; open it in a
                                                         browser logged in as an owner of ORG, click Create
  hack/github-app.py installs --slug SLUG                list the App's installations with its own JWT

`create` uses GitHub's App manifest flow (docs.github.com "Registering a GitHub App from a manifest"): GitHub hands back
a one-time code, this script exchanges it for the App's private key and writes it to ~/keys/<slug>.pem (mode 0600)
plus non-secret IDs to ~/keys/<slug>.json. The key is never printed. --public-url lets a phone finish the flow through
an HTTPS tunnel you control (for example `tailscale serve --set-path /ghapp http://127.0.0.1:8765/ghapp`); plain http
is accepted only on loopback. Stdlib only; the JWT is signed with `openssl`.
"""
import argparse, base64, html, http.server, json, os, secrets, stat, subprocess, sys, time, urllib.parse, urllib.request

PORT = 8765
KEYS = os.path.expanduser(os.environ.get("GITHUB_APP_KEYS_DIR", "~/keys"))
API = "https://api.github.com"
# forking.md (c): Contents, Pull requests, Workflows (templates commit .github/workflows/*) write; Administration
# write = repository creation in the org; Metadata read. No webhook, no events.
PERMISSIONS = {"administration": "write", "contents": "write", "metadata": "read",
               "pull_requests": "write", "workflows": "write"}


def manifest(org, public_url):
    return {
        "name": f"{org}-scaffolder"[:34],
        "url": "https://github.com/koorikla/platform",
        "description": "Backstage scaffolder: creates app repos in the org and opens the platform PR "
                       "(koorikla/platform docs/forking.md credentials (c)).",
        "redirect_url": f"{public_url}/callback",
        "hook_attributes": {"url": "https://example.invalid/unused", "active": False},
        "public": True,   # installable on a second account too (the owner of the platform repo)
        "default_permissions": PERMISSIONS,
        "default_events": [],
    }


def check_public_url(url):
    u = urllib.parse.urlparse(url)
    if u.scheme == "https" or (u.scheme == "http" and u.hostname in ("127.0.0.1", "localhost", "::1")):
        return url.rstrip("/")
    sys.exit(f"--public-url must be https (or http on loopback): {url}")


def api(path, token, method="GET", scheme="Bearer"):
    req = urllib.request.Request(API + path, method=method, headers={
        "Accept": "application/vnd.github+json", **({"Authorization": f"{scheme} {token}"} if token else {})})
    return json.load(urllib.request.urlopen(req))


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def app_jwt(slug):
    meta = json.load(open(os.path.join(KEYS, f"{slug}.json")))
    now = int(time.time())
    signing_input = b64(json.dumps({"alg": "RS256", "typ": "JWT"}).encode()) + "." + \
        b64(json.dumps({"iat": now - 60, "exp": now + 540, "iss": str(meta["id"])}).encode())
    sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", os.path.join(KEYS, f"{slug}.pem")],
                         input=signing_input.encode(), capture_output=True, check=True).stdout
    return signing_input + "." + b64(sig)


def create(org, public_url):
    state = secrets.token_urlsafe(24)
    form = json.dumps(manifest(org, public_url))
    action = f"https://github.com/organizations/{urllib.parse.quote(org)}/settings/apps/new?state={state}"

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, format, *args):  # noqa: A002 (stdlib signature); keep the one-time code out of logs
            pass

        def reply(self, code, body):
            self.send_response(code)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(body.encode())

        def do_GET(self):
            u = urllib.parse.urlparse(self.path)
            path = "/" + u.path.rstrip("/").rsplit("/ghapp", 1)[-1].lstrip("/")   # served at / or under /ghapp
            if path == "/":
                return self.reply(200, f'<form method="post" action="{html.escape(action)}">'
                                       f'<input type="hidden" name="manifest" value="{html.escape(form)}">'
                                       f'<p>GitHub App for <b>{html.escape(org)}</b></p>'
                                       f'<button type="submit">Continue to GitHub</button></form>')
            if path != "/callback":
                return self.reply(404, "not found")
            q = urllib.parse.parse_qs(u.query)
            if not secrets.compare_digest(q.get("state", [""])[0], state) or not q.get("code"):
                return self.reply(400, "state mismatch")
            app = api(f"/app-manifests/{urllib.parse.quote(q['code'][0])}/conversions", None, "POST")
            os.makedirs(KEYS, mode=0o700, exist_ok=True)
            fd = os.open(os.path.join(KEYS, f"{app['slug']}.pem"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
                         stat.S_IRUSR | stat.S_IWUSR)
            with os.fdopen(fd, "w") as f:
                f.write(app["pem"])
            meta = {"id": app["id"], "slug": app["slug"], "owner": app["owner"]["login"], "html_url": app["html_url"]}
            with open(os.path.join(KEYS, f"{app['slug']}.json"), "w") as f:
                json.dump(meta, f, indent=2)
            print(json.dumps(meta), flush=True)
            self.reply(200, f'<p>Created {html.escape(app["slug"])} (App ID {app["id"]}); key saved on the host.</p>'
                            f'<p><a href="{html.escape(app["html_url"])}/installations/new">Install it</a>.</p>')
            raise SystemExit(0)

    print(f"open {public_url}/ (listening on 127.0.0.1:{PORT})", flush=True)
    try:
        http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
    except SystemExit:
        pass


def installs(slug):
    for i in api("/app/installations", app_jwt(slug)):
        print(json.dumps({"installation_id": i["id"], "account": i["account"]["login"],
                          "repository_selection": i["repository_selection"], "permissions": i["permissions"]}))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("manifest", "create"):
        s = sub.add_parser(name)
        s.add_argument("--org", required=True)
        s.add_argument("--public-url", default=f"http://127.0.0.1:{PORT}")
    sub.add_parser("installs").add_argument("--slug", required=True)
    a = p.parse_args()
    if a.cmd == "installs":
        return installs(a.slug)
    url = check_public_url(a.public_url)
    if a.cmd == "manifest":
        return print(json.dumps(manifest(a.org, url), indent=2))
    create(a.org, url)


if __name__ == "__main__":
    main()
