#!/usr/bin/env python3
"""Chart.lock sync check, offline: recompute the digest `helm dependency build` compares against Chart.lock.

helm (pkg/downloader manager.Build -> resolver.HashReq) refuses a chart whose lock digest differs from
sha256(json([Chart.yaml dependencies, Chart.lock dependencies])), with "Chart.lock is out of sync". hack/deps.sh skips
charts that already have a charts/ dir, so a stale lock only shows on a clean tree (and in Argo CD's repo-server).
This check runs on every chart, cached or not.

Usage: chartlock.py <chart dir>...   -> one line per stale or missing lock, exit 1 if any.
       chartlock.py --tarballs <chart dir>...   -> vendored dependency tarballs vs pinned digests (below), exit 1 if any
       differs or is unpinned.
Stdlib only: the YAML is read through yq (mise) as JSON.

Digest pins: helm cannot pin a dependency by digest (`version: x@sha256:...` is an invalid constraint), so a chart may
list the sha256 of each locked tarball in the Chart.yaml annotation DIGESTS_ANNOTATION, one `<name>-<version>.tgz
sha256:<hex>` per line. That sha256 is the chart's OCI layer digest and the `digest` of a classic index.yaml entry. Once
a chart has the annotation, every Chart.lock dependency needs a pin and every pin a locked dependency.
"""
import os
import hashlib
import json
import subprocess
import sys

# json field order and omitempty of helm's chart.Dependency (pkg/chart/v2/dependency.go).
FIELDS = [("name", False), ("version", True), ("repository", False), ("condition", True), ("tags", True),
          ("enabled", True), ("import-values", True), ("alias", True)]


def load(path):
    out = subprocess.run(["yq", "-o", "json", ".", path], check=True, capture_output=True, text=True).stdout
    return json.loads(out) or {}


def dep(d):
    o = {}
    for k, omit in FIELDS:
        v = d.get(k)
        if omit and (v is None or v == "" or v == [] or v is False):
            continue
        o[k] = "" if v is None and not omit else v
    return o


def go_json(v):
    # encoding/json: compact, HTML-escaped, map keys in struct order (dicts above are already ordered)
    s = json.dumps(v, separators=(",", ":"), ensure_ascii=False)
    return s.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")


def digest(chart_dir):
    meta = load(f"{chart_dir}/Chart.yaml")
    lock = load(f"{chart_dir}/Chart.lock")
    req = [dep(d) for d in meta.get("dependencies") or []]
    locked = [dep(d) for d in lock.get("dependencies") or []]
    return "sha256:" + hashlib.sha256(go_json([req, locked]).encode()).hexdigest(), lock.get("digest")


DIGESTS_ANNOTATION = "platform.koorikla.io/dependency-digests"


def pins(meta):
    raw = (meta.get("annotations") or {}).get(DIGESTS_ANNOTATION)
    if raw is None:
        return None
    out = {}
    for line in raw.splitlines():
        if line.strip():
            name, _, sha = line.strip().partition(" ")
            out[name] = sha.strip()
    return out


def check_tarballs(d):
    """Problems (strings) of chart dir d's vendored tarballs against its pins; [] when unpinned or all match."""
    with open(f"{d}/Chart.yaml", encoding="utf-8") as f:
        if DIGESTS_ANNOTATION not in f.read():  # skip the yq call for the (many) charts without pins
            return []
    want = pins(load(f"{d}/Chart.yaml"))
    if want is None:
        return []
    locked = [f"{x['name']}-{x['version']}.tgz" for x in load(f"{d}/Chart.lock").get("dependencies") or []]
    bad = [f"{d}: {t} has no pinned digest in Chart.yaml annotation {DIGESTS_ANNOTATION}" for t in locked
           if t not in want]
    bad += [f"{d}: pinned digest for {t} matches no Chart.lock dependency" for t in want if t not in locked]
    for t in locked:
        path = f"{d}/charts/{t}"
        if t not in want or not os.path.isfile(path):
            continue
        with open(path, "rb") as f:
            have = "sha256:" + hashlib.sha256(f.read()).hexdigest()
        if have != want[t]:
            bad.append(f"{d}: charts/{t} is {have}, pinned {want[t]}")
    return bad


def main(dirs):
    if dirs[:1] == ["--tarballs"]:
        bad = [line for d in dirs[1:] for line in check_tarballs(d)]
        for line in bad:
            print(line)
        return 1 if bad else 0
    bad = 0
    for d in dirs:
        if not os.path.isfile(f"{d}/Chart.lock"):
            print(f"{d}: dependencies without a Chart.lock (run: helm dependency update {d})")
            bad += 1
            continue
        want, have = digest(d)
        if want != have:
            print(f"{d}: Chart.lock out of sync with Chart.yaml (run: helm dependency update {d})")
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
