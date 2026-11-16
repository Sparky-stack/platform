#!/usr/bin/env python3
"""Chart.lock sync check, offline: recompute the digest `helm dependency build` compares against Chart.lock.

helm (pkg/downloader manager.Build -> resolver.HashReq) refuses a chart whose lock digest differs from
sha256(json([Chart.yaml dependencies, Chart.lock dependencies])), with "Chart.lock is out of sync". hack/deps.sh skips
charts that already have a charts/ dir, so a stale lock only shows on a clean tree (and in Argo CD's repo-server).
This check runs on every chart, cached or not.

Usage: chartlock.py <chart dir>...   -> one line per stale or missing lock, exit 1 if any.
Stdlib only: the YAML is read through yq (mise) as JSON.
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


def main(dirs):
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
