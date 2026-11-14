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
# Configuration: environment variables (see the ClusterWorkflow). Exit code != 0 = gate failed (the WorkflowRun fails).
# Stdlib only. Template note: the ClusterWorkflow embeds this file in a CEL-templated runTemplate and Argo templates
# it again, so the source must not contain a dollar sign followed by an opening brace, nor two opening braces.
import base64
import datetime as dt
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
        "client_secret": env("CLIENT_SECRET"),
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


# --- GitHub ---------------------------------------------------------------------------------------------------------
def gh(method, path, body=None, ok=(200, 201)):
    return http(method, "https://api.github.com" + path, token=env("GITHUB_TOKEN"), body=body,
                headers={"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}, ok=ok)


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

    # 6. promote by pull request
    repo = env("REPOSITORY")
    if not repo:
        wl = api("/api/v1/namespaces/%s/workloads?component=%s" % (ns, component), tok).get("items") or []
        repo = ((wl[0].get("spec") or {}).get("source") or {}).get("repository", "") if wl else ""
    repo = re.sub(r"^https://github\.com/|\.git$", "", repo)
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repo):
        raise GateFailed("no GitHub repository for %s (Workload spec.source.repository or parameter repository)" % component)
    path = env("BINDING_PATH").replace("{environment}", target)
    if env("DRY_RUN", "false") == "true":
        log("  dry run: would open a PR in %s setting %s releaseName=%s" % (repo, path, release))
        return
    promote(repo, path, target, release, evidence)


if __name__ == "__main__":
    try:
        main()
    except GateFailed as e:
        log("GATE FAILED: %s" % e)
        sys.exit(1)
