#!/usr/bin/env python3
"""Every box of every generated diagram is named in the doc that owns its topic, so diagrams cannot drift from docs.

The owning doc(s) of each diagram: the "Owning doc" column of docs/diagrams/README.md (every link in the cell). A box
is covered when its title, name= or aka (docs/diagrams/src/build.py) appears in an owning doc as a phrase (case,
backticks, "&"/"and" and plurals ignored; the last word may be a prefix: "Admission control" ~ "admission controller").
Box titles are plain words and docs use identifiers (docs/diagrams/README.md "Visual system"), so ALIASES names the
term the doc uses instead; it is checked like a title. DIAGRAM_ONLY lists the few boxes no owning doc needs to name.
An entry that no longer matches a box, or whose title the doc now names, fails as stale.

Usage: check-diagram-labels.py [--readme PATH] [DIAGRAM...]   (default: docs/diagrams/README.md, every diagram)
"""
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "docs", "diagrams", "src"))
import build  # noqa: E402

# (diagram, box title): the term the owning doc uses for that component.
ALIASES = {
    ("architecture", "Shared services"): "OpenBao",
    ("security", "Auto-response"): "Talon",
    ("security", "Incident workflow"): "falco-response",
    ("network", "App pods"): "pod",
    ("sdlc", "Build & sign"): "build",
    ("sdlc", "New release"): "ComponentRelease",
    ("sdlc", "Promote to staging"): "staging",
    ("sdlc", "Promote to production"): "production",
    ("cluster-lifecycle", "k3s nodes"): "k3s",
    ("cluster-lifecycle", "cluster-agent"): "agent",
    ("trust", "Cluster API"): "CAPI",
    ("trust", "Mesh proxies"): "ztunnel",
    ("backup", "Backup copies"): "backup",
    ("backup", "Secret backend"): "OpenBao",
    ("upgrade", "Maintainer"): "merge",
    ("delivery-lanes", "App CI"): "app-container",
    ("delivery-lanes", "Signed image"): "signature",
    ("delivery-lanes", "Deploy folder"): "deploy",
    ("delivery-lanes", "Infra CI"): "CI",
    ("delivery-lanes", "Main branch"): "main",
    ("delivery-lanes", "Package CI"): "package",
    ("delivery-lanes", "Signed package"): "package",
    ("delivery-lanes", "Package pin"): "pin",
    ("lane-apps", "Registry"): "Harbor",
    ("lane-apps", "Deploy folder"): "deploy",
    ("lane-infra", "Main branch"): "main",
    ("lane-extensions", "Package CI"): "package",
    ("lane-extensions", "Registry"): "Harbor",
    ("lane-extensions", "Package pin"): "pin",
    ("lane-extensions", "Signature check"): "signature",
    ("app-database-map", "PostgreSQL claim"): "PostgreSQL",
    ("app-database-map", "App secret"): "secret",
    ("app-database-map", "Connection secret"): "secret",
    ("app-database-map", "App pods"): "Deployment",
}

# (diagram, box title): why the owning doc need not name it. Keep this short.
DIAGRAM_ONLY = {
    ("network", "cluster-gateway"): "context box (the agent's mgmt endpoint), owned by observability.md, not networking",
    ("lane-extensions", "Other extensions"): "context box pointing at the other two lanes, not a component",
}

ROW = re.compile(r"^\|\s*\[([\w-]+)\.svg\]\([^)]*\)\s*\|.*\|([^|]*)\|\s*$")


def words(text):
    text = text.lower().replace("`", "").replace("&", " and ")
    out = []
    for w in re.findall(r"[a-z0-9]+", text):
        w = re.sub(r"ies$", "y", w) if len(w) > 4 else w
        out.append(w[:-1] if len(w) > 3 and w.endswith("s") and not w.endswith("ss") else w)
    return " ".join(out)


def rel(path):
    """Repo-relative POSIX path; the path itself when on another drive (Windows temp dirs)."""
    try:
        return os.path.relpath(path, ROOT).replace(os.sep, "/")
    except ValueError:
        return path


def owners(readme):
    base = os.path.dirname(readme)
    with open(readme, encoding="utf-8") as fh:
        rows = [ROW.match(l) for l in fh.read().splitlines()]
    return {m.group(1): [os.path.normpath(os.path.join(base, t.split("#")[0]))
                         for t in re.findall(r"\]\(([^)]+)\)", m.group(2))] for m in rows if m}


def main(argv):
    readme = os.path.join(ROOT, "docs", "diagrams", "README.md")
    if argv[:1] == ["--readme"]:
        readme, argv = argv[1], argv[2:]
    names = argv or list(build.DIAGRAMS)
    own, problems, seen = owners(readme), [], set()
    for n in names:
        docs = own.get(n)
        if not docs:
            problems.append("%s: no owning doc in %s" % (n, rel(readme)))
            continue
        text = " " + " ".join(words(open(d, encoding="utf-8").read()) for d in docs) + " "
        where = ", ".join(rel(d) for d in docs)
        has = lambda term: (" " + words(term)) in text  # noqa: E731
        for info in build.DIAGRAMS[n]().box_info.values():
            key = (n, info["title"])
            seen.add(key)
            named = any(has(t) for t in {info["title"], info["name"], *info["aka"]})
            if key in ALIASES or key in DIAGRAM_ONLY:
                if named:
                    problems.append('%s: "%s" is now named in %s: drop its stale entry' % (n, key[1], where))
                elif key in ALIASES and not has(ALIASES[key]):
                    problems.append('%s: box "%s" (doc term "%s") not in %s' % (n, key[1], ALIASES[key], where))
            elif not named:
                problems.append('%s: box "%s" not in %s (name it there, or add an entry here)' % (n, key[1], where))
    for key in sorted((set(ALIASES) | set(DIAGRAM_ONLY)) - seen):
        if key[0] in names:
            problems.append('%s: stale entry "%s": no such box' % key)
    for p in problems:
        print("  FAIL " + p)
    print("diagram labels: %d problem(s)" % len(problems) if problems else "diagram labels OK")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
