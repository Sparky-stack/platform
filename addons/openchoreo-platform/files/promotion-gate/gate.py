#!/usr/bin/env python3
# Promotion gate (addon openchoreo-platform, ClusterWorkflow promotion-gate; docs/promotion.md).
#
# Runs in the OpenChoreo workflow plane for one component and one promotion edge (source -> target environment):
#   1. pipeline   the edge exists in the project's DeploymentPipeline (1.3.3 does not enforce it server-side)
#   2. readiness  the source ReleaseBinding is Ready, its rollout succeeded, it runs the release being promoted
#   3. smoke      HTTP GET on every external endpoint of the source binding answers 2xx/3xx
#   4. observe    observer API: no alert fired for the component in the source environment during the window, HTTP
#                 error rate below the threshold
#   5. freeze     no freeze window is active for the target environment
#   6. promote    opens (or updates) a pull request in the app repo that sets spec.releaseName of the target
#                 environment's ReleaseBinding, and sets the commit status the branch protection requires.
# Nothing is applied to any cluster: Argo CD syncs the merged PR (declarative path to production).
#
# The repository is the component's Workload spec.source.repository (never a run parameter) and must belong to the
# installation's GitHub owner. GitHub access: the gate's own GitHub App (store key promotion-gate-github). The gate
# signs an App JWT, mints an installation token scoped to exactly that repository with contents, pull_requests and
# statuses write, and revokes it when done (token lifetime <= 1h either way).
#
# Configuration: environment variables (see the ClusterWorkflow); secrets as files in SECRETS_DIR. Exit code != 0 =
# gate failed (the WorkflowRun fails). Stdlib only. Template note: the ClusterWorkflow embeds this file in a CEL-templated runTemplate and Argo templates
# it again, so the source must not contain a dollar sign followed by an opening brace, nor two opening braces.
import base64
import datetime as dt
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zoneinfo


def env(name, default=""):
    return os.environ.get(name, default).strip()


def secret(name):
    """Secret value from SECRETS_DIR/<name> (mounted Secret volume); env var fallback for local runs and tests."""
    path = os.path.join(env("SECRETS_DIR", "/var/run/secrets/promotion-gate"), name)
    if os.path.isfile(path):
        with open(path) as f:
            return f.read().strip()
    return env(name.upper().replace("-", "_"))


def log(msg):
    print(msg, flush=True)


class GateFailed(Exception):
    pass


def http(method, url, token=None, body=None, headers=None, form=None, timeout=20, ok=(200, 201)):
    hdrs = {"Accept": "application/json", "User-Agent": "koorikla-promotion-gate"}
    hdrs.update(headers or {})
    data = None
    if token:
        hdrs["Authorization"] = "Bearer " + token
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        hdrs["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode()
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            status = resp.status
    except urllib.error.HTTPError as e:
        raw, status = e.read(), e.code
    if status not in ok:
        raise GateFailed("%s %s -> HTTP %d: %s" % (method, url, status, raw[:300].decode(errors="replace")))
    return json.loads(raw) if raw else {}


# --- freeze windows -------------------------------------------------------------------------------------------------
DAYS = {"mon": 0, "tue": 1, "wed": 2, "thu": 3, "fri": 4, "sat": 5, "sun": 6}


def minute_of_week(spec):
    """'Fri 16:00' -> minutes since Monday 00:00."""
    m = re.fullmatch(r"\s*([A-Za-z]{3})[a-z]*\s+(\d{1,2}):(\d{2})\s*", spec)
    if not m or m.group(1).lower() not in DAYS:
        raise ValueError("bad freeze window bound %r (want e.g. 'Fri 16:00')" % spec)
    return DAYS[m.group(1).lower()] * 1440 + int(m.group(2)) * 60 + int(m.group(3))


def active_freeze(windows, target_env, now_utc):
    """Return the first active weekly window for target_env, or None. Windows wrap around the week end."""
    for w in windows:
        envs = w.get("environments") or []
        if envs and target_env not in envs:
            continue
        local = now_utc.astimezone(zoneinfo.ZoneInfo(w.get("timeZone", "UTC")))
        now = local.weekday() * 1440 + local.hour * 60 + local.minute
        start, end = minute_of_week(w["start"]), minute_of_week(w["end"])
        inside = start <= now < end if start < end else (now >= start or now < end)
        if inside:
            return w
    return None


# --- OpenChoreo -----------------------------------------------------------------------------------------------------
def token():
    if env("GATE_TOKEN"):
        return env("GATE_TOKEN")
    resp = http("POST", env("TOKEN_URL"), form={
        "grant_type": "client_credentials",
        "client_id": env("CLIENT_ID"),
        "client_secret": secret("client-secret"),
    })
    return resp["access_token"]


def api(path, tok):
    return http("GET", env("API_URL").rstrip("/") + path, token=tok)


def condition(obj, ctype):
    for c in (obj.get("status") or {}).get("conditions") or []:
        if c.get("type") == ctype:
            return c
    return {}


def next_environment(pipeline, source):
    for p in (pipeline.get("spec") or {}).get("promotionPaths") or []:
        if p["sourceEnvironmentRef"]["name"] == source:
            return [t["name"] for t in p.get("targetEnvironmentRefs") or []]
    return []


def endpoint_urls(binding):
    urls = []
    for ep in (binding.get("status") or {}).get("endpoints") or []:
        ext = ep.get("externalURLs") or {}
        for scheme in ("https", "http"):
            u = ext.get(scheme)
            if u:
                port = u.get("port")
                default = 443 if u.get("scheme", scheme) == "https" else 80
                host = u["host"] + ("" if not port or port == default else ":%d" % port)
                urls.append("%s://%s%s" % (u.get("scheme", scheme), host, u.get("path", "")))
                break
    return urls


def smoke(urls, path, attempts=5):
    for base in urls:
        url = base.rstrip("/") + "/" + path.lstrip("/")
        last = ""
        for i in range(attempts):
            try:
                req = urllib.request.Request(url, headers={"User-Agent": "koorikla-promotion-gate"})
                with urllib.request.urlopen(req, timeout=10) as resp:
                    if 200 <= resp.status < 400:
                        log("  smoke ok  %s -> %d" % (url, resp.status))
                        break
                    last = "HTTP %d" % resp.status
            except Exception as e:  # noqa: BLE001 - any failure is a failed probe
                last = str(e)
            time.sleep(3 * (i + 1))
        else:
            raise GateFailed("smoke test failed: %s (%s)" % (url, last))


def observe(tok, scope, window_minutes, max_error_rate):
    end = dt.datetime.now(dt.timezone.utc)
    start = end - dt.timedelta(minutes=window_minutes)
    times = {"startTime": start.isoformat().replace("+00:00", "Z"), "endTime": end.isoformat().replace("+00:00", "Z")}
    base = env("OBSERVER_URL").rstrip("/")
    alerts = http("POST", base + "/api/v1alpha1/alerts/query", token=tok,
                  body=dict(times, limit=20, searchScope=scope))
    fired = alerts.get("total", len(alerts.get("alerts") or []))
    if fired:
        names = sorted({((a.get("metadata") or {}).get("alertRuleName") or a.get("alertId") or "?")
                        for a in alerts.get("alerts") or []})
        raise GateFailed("%d alert(s) fired in the last %dm: %s" % (fired, window_minutes, ", ".join(names)))
    log("  observe   no alerts in the last %dm" % window_minutes)
    metrics = http("POST", base + "/api/v1/metrics/query", token=tok,
                   body=dict(times, metric="http", step="1m", searchScope=scope))
    total = sum(p.get("value") or 0 for p in metrics.get("requestCount") or [])
    failed = sum(p.get("value") or 0 for p in metrics.get("unsuccessfulRequestCount") or [])
    if total <= 0:
        log("  observe   no HTTP traffic recorded (error rate not evaluated)")
        return "no traffic"
    rate = failed / total
    log("  observe   HTTP error rate %.4f (%d/%d), max %.4f" % (rate, failed, total, max_error_rate))
    if rate > max_error_rate:
        raise GateFailed("HTTP error rate %.4f above %.4f" % (rate, max_error_rate))
    return "error rate %.4f" % rate


# --- GitHub App token -------------------------------------------------------------------------------------------------
# RS256 (RSASSA-PKCS1-v1_5 + SHA-256, RFC 8017 8.2) for the App JWT, stdlib only: the signature is deterministic, so
# the only concern of a hand-written signer is timing; it signs one JWT per run in a short-lived pod with no oracle.
# hack/tests checks it against openssl. Keys: PKCS#1 (GitHub's "BEGIN RSA PRIVATE KEY") or PKCS#8.
SHA256_DIGEST_INFO = bytes.fromhex("3031300d060960864801650304020105000420")
GATE_PERMISSIONS = {"contents": "write", "pull_requests": "write", "statuses": "write"}


def _der(buf, i):
    """One DER TLV at buf[i:] -> (tag, value, next index)."""
    tag, length = buf[i], buf[i + 1]
    i += 2
    if length & 0x80:
        n = length & 0x7F
        length = int.from_bytes(buf[i:i + n], "big")
        i += n
    return tag, buf[i:i + length], i + length


def _seq(body):
    out, i = [], 0
    while i < len(body):
        tag, value, i = _der(body, i)
        out.append((tag, value))
    return out


def rsa_private_key(pem):
    """PEM RSA private key -> (n, e, d)."""
    m = re.search(r"-----BEGIN (RSA )?PRIVATE KEY-----(.+?)-----END", pem, re.S)
    if not m:
        raise GateFailed("GitHub App private key is not a PEM RSA private key")
    _, body, _ = _der(base64.b64decode("".join(m.group(2).split())), 0)
    items = _seq(body)
    if not m.group(1):  # PKCS#8 PrivateKeyInfo: version, algorithm, OCTET STRING(RSAPrivateKey)
        _, body, _ = _der(items[2][1], 0)
        items = _seq(body)
    n, e, d = (int.from_bytes(items[k][1], "big") for k in (1, 2, 3))
    return n, e, d


def rs256(message, key):
    n, _, d = key
    k = (n.bit_length() + 7) // 8
    t = SHA256_DIGEST_INFO + hashlib.sha256(message).digest()
    if k < len(t) + 11:
        raise GateFailed("RSA key too short")
    em = b"\x00\x01" + b"\xff" * (k - len(t) - 3) + b"\x00" + t
    return pow(int.from_bytes(em, "big"), d, n).to_bytes(k, "big")


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def app_jwt(app_id, key, now=None):
    now = int(now if now is not None else time.time())
    head = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}, separators=(",", ":")).encode())
    claims = b64url(json.dumps({"iat": now - 60, "exp": now + 540, "iss": str(app_id)}, separators=(",", ":")).encode())
    signing_input = (head + "." + claims).encode()
    return head + "." + claims + "." + b64url(rs256(signing_input, key))


GH_HEADERS = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
_GH_TOKEN = {"value": ""}


def installation_token(repo):
    """Installation token of the gate's App, limited to `repo` (owner/name) and GATE_PERMISSIONS."""
    key = rsa_private_key(secret("github-app-private-key"))
    jwt = app_jwt(secret("github-app-id"), key)
    resp = http("POST", "https://api.github.com/app/installations/%s/access_tokens" % secret("github-app-installation-id"),
                token=jwt, headers=GH_HEADERS, body={"repositories": [repo.split("/", 1)[1]], "permissions": GATE_PERMISSIONS})
    return resp["token"]


def revoke_token():
    if _GH_TOKEN["value"]:
        try:
            http("DELETE", "https://api.github.com/installation/token", token=_GH_TOKEN["value"], headers=GH_HEADERS,
                 ok=(204,))
        except Exception as e:  # noqa: BLE001 - expires within the hour anyway
            log("  warning: could not revoke the GitHub token: %s" % e)
        _GH_TOKEN["value"] = ""


# --- GitHub ---------------------------------------------------------------------------------------------------------
def gh(method, path, body=None, ok=(200, 201)):
    return http(method, "https://api.github.com" + path, token=_GH_TOKEN["value"], body=body, headers=GH_HEADERS, ok=ok)


def workload_repository(workloads, project, component, owner):
    """owner/repo from the component's Workload spec.source.repository; must be a GitHub repo of `owner`."""
    mine = [w for w in workloads
            if ((w.get("spec") or {}).get("owner") or {}).get("componentName") == component
            and ((w.get("spec") or {}).get("owner") or {}).get("projectName") == project]
    if len(mine) != 1:
        raise GateFailed("expected one Workload for %s/%s, found %d" % (project, component, len(mine)))
    url = ((mine[0].get("spec") or {}).get("source") or {}).get("repository", "")
    m = re.fullmatch(r"https://github\.com/([A-Za-z0-9-]+)/([A-Za-z0-9_.-]+?)(\.git)?/?", url)
    if not m or m.group(2) in (".", ".."):
        raise GateFailed("Workload spec.source.repository %r is not a https://github.com/<owner>/<repo> URL" % url)
    if owner and m.group(1).lower() != owner.lower():
        raise GateFailed("repository %s/%s is outside the installation's GitHub owner %s" % (m.group(1), m.group(2), owner))
    return "%s/%s" % (m.group(1), m.group(2))


def set_release(text, release):
    """Set spec.releaseName in a ReleaseBinding manifest, keeping comments and layout."""
    line = re.compile(r"^(?P<indent>[ \t]*)#?[ \t]*releaseName:.*$", re.M)
    if line.search(text):
        return line.sub(lambda m: "%sreleaseName: %s" % (m.group("indent"), release), text, count=1)
    envline = re.compile(r"^(?P<indent>[ \t]+)environment:.*$", re.M)
    m = envline.search(text)
    if not m:
        raise GateFailed("cannot place releaseName: no spec.environment line in the binding file")
    return text[:m.end()] + "\n%sreleaseName: %s" % (m.group("indent"), release) + text[m.end():]


def promote(repo, path, target, release, evidence):
    base = env("BASE_BRANCH", "main")
    branch = "promote/%s-%s" % (env("COMPONENT"), target)
    current = gh("GET", "/repos/%s/contents/%s?ref=%s" % (repo, path, base))
    text = base64.b64decode(current["content"]).decode()
    updated = set_release(text, release)
    if updated == text:
        log("  promote   %s already pins %s on %s: nothing to do" % (path, release, base))
        return None
    head = gh("GET", "/repos/%s/git/ref/heads/%s" % (repo, base))["object"]["sha"]
    try:
        gh("POST", "/repos/%s/git/refs" % repo, {"ref": "refs/heads/" + branch, "sha": head})
    except GateFailed:
        gh("PATCH", "/repos/%s/git/refs/heads/%s" % (repo, branch), {"sha": head, "force": True})
    title = "promote(%s): %s to %s" % (env("COMPONENT"), release, target)
    commit = gh("PUT", "/repos/%s/contents/%s" % (repo, path), {
        "message": title + "\n\nOpened by the OpenChoreo promotion gate (" + env("RUN_NAME", "manual") + ").",
        "content": base64.b64encode(updated.encode()).decode(),
        "branch": branch,
        "sha": current["sha"],
    })["commit"]["sha"]
    owner = repo.split("/")[0]
    pulls = gh("GET", "/repos/%s/pulls?state=open&head=%s:%s" % (repo, owner, branch))
    body = "Gate evidence (`%s`):\n\n%s\n\nMerge = deploy to `%s` (Argo CD syncs the binding). Requires the `%s` " \
           "status and a CODEOWNERS approval." % (env("RUN_NAME", "manual"), "\n".join("- " + e for e in evidence),
                                                   target, env("STATUS_CONTEXT"))
    if pulls:
        pr = gh("PATCH", "/repos/%s/pulls/%d" % (repo, pulls[0]["number"]), {"title": title, "body": body})
    else:
        pr = gh("POST", "/repos/%s/pulls" % repo, {"title": title, "head": branch, "base": base, "body": body})
    gh("POST", "/repos/%s/statuses/%s" % (repo, commit), {
        "state": "success",
        "context": env("STATUS_CONTEXT"),
        "description": ("%s verified in %s" % (release, env("SOURCE_ENV")))[:140],
    })
    log("  promote   %s" % pr["html_url"])
    return pr["html_url"]


def main():
    ns, project, component = env("NAMESPACE"), env("PROJECT"), env("COMPONENT")
    source, target, release = env("SOURCE_ENV"), env("TARGET_ENV"), env("RELEASE")
    log("promotion gate: %s/%s %s -> %s" % (project, component, source, target or "(next)"))
    tok = token()

    # 1. pipeline
    proj = api("/api/v1/namespaces/%s/projects/%s" % (ns, project), tok)
    pipeline_name = proj["spec"]["deploymentPipelineRef"]["name"]
    pipeline = api("/api/v1/namespaces/%s/deploymentpipelines/%s" % (ns, pipeline_name), tok)
    targets = next_environment(pipeline, source)
    if not target:
        if len(targets) != 1:
            raise GateFailed("%s has %d targets in pipeline %s; set targetEnvironment" % (source, len(targets), pipeline_name))
        target = targets[0]
    if target not in targets:
        raise GateFailed("pipeline %s has no promotion path %s -> %s" % (pipeline_name, source, target))
    if env("GATED_TARGETS") and target not in json.loads(env("GATED_TARGETS")):
        log("  %s is not a gated target: nothing to do" % target)
        return
    log("  pipeline  %s: %s -> %s" % (pipeline_name, source, target))

    # 2. readiness of the source binding
    bindings = api("/api/v1/namespaces/%s/releasebindings?component=%s" % (ns, component), tok).get("items") or []
    src = next((b for b in bindings if b["spec"].get("environment") == source), None)
    if not src:
        raise GateFailed("no ReleaseBinding for %s in %s" % (component, source))
    running = src["spec"].get("releaseName", "")
    if release and release != running:
        raise GateFailed("%s runs %s in %s, not %s" % (component, running or "nothing", source, release))
    release = release or running
    if not release:
        raise GateFailed("%s has no release in %s" % (component, source))
    ready = condition(src, "Ready")
    if ready.get("status") != "True":
        raise GateFailed("ReleaseBinding %s not Ready: %s" % (src["metadata"]["name"], ready.get("message", "no condition")))
    delivery = (src.get("status") or {}).get("delivery") or {}
    if not delivery.get("succeededAt"):
        raise GateFailed("rollout of %s in %s has not succeeded yet" % (release, source))
    evidence = ["`%s` Ready in `%s`, rollout succeeded %s" % (release, source, delivery["succeededAt"])]
    log("  ready     %s in %s (rollout succeeded %s)" % (release, source, delivery["succeededAt"]))
    tgt = next((b for b in bindings if b["spec"].get("environment") == target), None)
    if tgt and tgt["spec"].get("releaseName") == release:
        log("  %s already runs %s: nothing to do" % (target, release))
        return

    # 3. smoke
    if env("SMOKE_HTTP", "true") == "true":
        urls = endpoint_urls(src)
        if urls:
            smoke(urls, env("SMOKE_PATH", "/"))
            evidence.append("smoke GET %s -> 2xx/3xx" % ", ".join(urls))
        else:
            log("  smoke     no external endpoint: skipped")
            evidence.append("smoke: no external endpoint")
    else:
        evidence.append("smoke: HTTP probe disabled for this installation")

    # 4. observe
    if env("OBSERVE", "true") == "true":
        scope = {"namespace": ns, "project": project, "component": component, "environment": source}
        result = observe(tok, scope, int(env("OBSERVE_WINDOW_MINUTES", "15")), float(env("MAX_ERROR_RATE", "0.05")))
        evidence.append("observer: no alerts in %sm, %s" % (env("OBSERVE_WINDOW_MINUTES", "15"), result))

    # 5. freeze
    frozen = active_freeze(json.loads(env("FREEZE_WINDOWS", "[]") or "[]"), target, dt.datetime.now(dt.timezone.utc))
    if frozen:
        raise GateFailed("freeze window active for %s: %s - %s %s" % (target, frozen["start"], frozen["end"],
                                                                      frozen.get("timeZone", "UTC")))
    evidence.append("no freeze window active for `%s`" % target)

    # 6. promote by pull request, in the repository the component's Workload comes from
    wl = api("/api/v1/namespaces/%s/workloads?component=%s" % (ns, component), tok).get("items") or []
    owner = re.sub(r"^https://github\.com/", "", env("GITHUB_OWNER_URL")).strip("/")
    repo = workload_repository(wl, project, component, owner)
    path = env("BINDING_PATH").replace("{environment}", target)
    if env("DRY_RUN", "false") == "true":
        log("  dry run: would open a PR in %s setting %s releaseName=%s" % (repo, path, release))
        return
    _GH_TOKEN["value"] = installation_token(repo)
    try:
        promote(repo, path, target, release, evidence)
    finally:
        revoke_token()


if __name__ == "__main__":
    try:
        main()
    except GateFailed as e:
        log("GATE FAILED: %s" % e)
        sys.exit(1)
