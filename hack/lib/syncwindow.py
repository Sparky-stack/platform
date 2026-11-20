#!/usr/bin/env python3
"""Argo CD Applications held OutOfSync by an active deny sync window (docs/promotion.md#freeze-windows).

Usage: syncwindow.py <applications.json> <appprojects.json> [now]
  inputs: `kubectl get applications.argoproj.io|appprojects.argoproj.io -n argocd -o json`; now: ISO 8601
  [current time]. Prints "<app>\t<window description>\t<window end (ISO 8601, window time zone)>" per OutOfSync
  Application that an active deny window of its AppProject names in `applications` (globs). Argo CD exposes no
  "blocked by window" status on the Application, so the window is evaluated here like the controller does: active
  when its cron `schedule` (5 fields: *, lists, ranges, steps) fired in `timeZone` within the last `duration`.
  Windows matching only by namespaces/clusters are ignored (the app then stays a failure). Stdlib only.
"""
import datetime as dt
import fnmatch
import json
import re
import sys

UTC = dt.timezone.utc


def zone(name):
    if name in ("", "UTC", "Etc/UTC"):
        return UTC
    from zoneinfo import ZoneInfo  # needs a tz database (OS or the tzdata package)
    return ZoneInfo(name)


def field(spec, lo, hi):
    vals = set()
    for part in spec.split(","):
        rng, _, step = part.partition("/")
        if rng == "*":
            a, b = lo, hi
        elif "-" in rng:
            a, b = (int(x) for x in rng.split("-", 1))
        else:
            a = b = int(rng)
            if step:
                b = hi
        vals.update(range(a, b + 1, int(step or 1)))
    return vals


def cron_match(schedule, t):
    m, h, dom, mon, dow = schedule.split()
    days = {d % 7 for d in field(dow, 0, 7)}
    dom_ok, dow_ok = t.day in field(dom, 1, 31), (t.isoweekday() % 7) in days
    day_ok = (dom_ok or dow_ok) if (dom != "*" and dow != "*") else (dom_ok and dow_ok)
    return t.minute in field(m, 0, 59) and t.hour in field(h, 0, 23) and t.month in field(mon, 1, 12) and day_ok


def duration(s):
    units = {"h": 3600, "m": 60, "s": 1}
    parts = re.findall(r"(\d+)([hms])", s)
    if not parts or "".join(n + u for n, u in parts) != s:
        raise ValueError("unsupported duration %r" % s)
    return dt.timedelta(seconds=sum(int(n) * units[u] for n, u in parts))


def active_until(w, now):
    """End of the active occurrence of window w at now, else None."""
    tz, dur = zone(w.get("timeZone", "")), duration(w["duration"])
    t = now.replace(second=0, microsecond=0)
    for _ in range(int(dur.total_seconds() // 60) + 1):
        if now - t < dur and cron_match(w["schedule"], t.astimezone(tz)):
            return (t + dur).astimezone(tz)
        t -= dt.timedelta(minutes=1)
    return None


def frozen(apps, projects, now):
    windows = {p["metadata"]["name"]: p.get("spec", {}).get("syncWindows") or [] for p in projects}
    for a in apps:
        name = a["metadata"]["name"]
        if a.get("status", {}).get("sync", {}).get("status") != "OutOfSync":
            continue
        for w in windows.get(a.get("spec", {}).get("project", "default"), []):
            if w.get("kind") != "deny" or not any(fnmatch.fnmatchcase(name, g) for g in w.get("applications") or []):
                continue
            end = active_until(w, now)
            if end:
                yield name, w.get("description") or w["schedule"], end.isoformat(timespec="minutes").replace("+00:00", "Z")
                break


def main(argv):
    if len(argv) not in (3, 4):
        sys.exit(__doc__)
    def load(path):
        with open(path, encoding="utf-8") as f:
            text = f.read().strip()
        return (json.loads(text).get("items") or []) if text else []

    now = dt.datetime.fromisoformat(argv[3].replace("Z", "+00:00")) if len(argv) == 4 else dt.datetime.now(UTC)
    if now.tzinfo is None:
        now = now.replace(tzinfo=UTC)
    for row in frozen(load(argv[1]), load(argv[2]), now):
        print("\t".join(row))


if __name__ == "__main__":
    main(sys.argv)
