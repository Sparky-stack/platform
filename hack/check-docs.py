#!/usr/bin/env python3
"""Check the repo's Markdown for references that do not resolve (task lint).

Checked in every *.md outside .git, vendored chart dependencies and project-template skeletons (templates/*/skeleton:
the docs of the repositories they become; hack/tests/test_project_templates.sh renders and checks them):
  - relative links and <img src>/<a href> targets exist; `#anchors` match a heading of the target file;
  - `doc.md "Section"` cross-references (in prose or code spans) match a heading of that doc;
  - repo paths in code spans (`addons/...`, `charts/...`, `hack/...`, `docs/...`, `installations/...`,
    `bootstrap/...`, `.github/...`, `.devcontainer/...`) exist, unless they hold a placeholder (<x>, *, {a,b}, $x, ...);
  - `task <name>` / `make <name>` in code spans and code blocks name a Taskfile task / Makefile target;
  - never `--context koorikla` / `use-context koorikla`; `docs/runbooks/*.md` are linked from `docs/operations.md`,
    carry the standard headings, and pass `--context` or `--kubeconfig` on every `kubectl` block command;
  - every `addons/*` and `charts/*` directory carries a `README.md` (<= 40 lines) with the standard headings.

Usage: check-docs.py [ROOT]   (default: the repo root). Exits 1 and lists every problem.
"""
import os
import re
import sys

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), ".."))
PATH_ROOTS = ("addons/", "charts/", "hack/", "docs/", "wiki/", "installations/", "bootstrap/", ".github/", ".devcontainer/")
PLACEHOLDER = re.compile(r"[<>*{}$…]|\.\.\.|\|")
LINK = re.compile(r"!?\[(?:[^\]\[]|\[[^\]]*\])*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
HTML_LINK = re.compile(r"<(?:img|a)\b[^>]*?\b(?:src|href)=\"([^\"]+)\"", re.I)
SECTION_REF = re.compile(r"([A-Za-z0-9_./-]*[A-Za-z0-9_-]\.md)`?,? \"([^\"]+)\"")
CODE_SPAN = re.compile(r"(`+)(.+?)\1")
CMD = re.compile(r"(?:^|[\s;&|(`])(task|make) ([a-z][a-z0-9:-]*)")
FORBIDDEN_CTX = re.compile(r"(?:--context(?:=|\s+)|use-context\s+)['\"]?koorikla\b")
KUBECTL_CMD = re.compile(r"(?:^|[;&|(`]\s*)kubectl\s+")
RUNBOOK_SECTIONS = ("when to use", "symptoms", "steps", "verify", "rollback", "related links")
CHART_README = re.compile(r"^(?:addons|charts)/[^/]+/README\.md$")
CHART_README_SECTIONS = ("purpose", "where it runs", "key values", "day-2 notes", "links")
CHART_README_MAX_LINES = 40


def md_files():
    for d, dirs, files in os.walk(ROOT):
        rel = os.path.relpath(d, ROOT)
        parts = [] if rel == "." else rel.split(os.sep)
        if ".git" in parts or "node_modules" in parts or (len(parts) >= 3 and parts[0] == "addons" and parts[2] == "charts") \
                or (len(parts) >= 3 and parts[0] == "templates" and parts[2] == "skeleton"):
            dirs[:] = []
            continue
        dirs.sort()
        for f in sorted(files):
            if f.endswith(".md"):
                yield os.path.join(d, f)


def slug(heading):
    """GitHub's heading anchor: lowercase, drop punctuation except - and _, spaces to -."""
    h = re.sub(r"<[^>]+>", "", heading).strip().lower()
    h = re.sub(r"[^\w\- ]", "", h)
    return h.replace(" ", "-")


_headings = {}


def headings(path):
    if path not in _headings:
        texts, slugs, seen, fence = [], set(), {}, False
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if line.lstrip().startswith(("```", "~~~")):
                    fence = not fence
                    continue
                m = None if fence else re.match(r"#{1,6}\s+(.*?)\s*#*\s*$", line)
                if m:
                    text = m.group(1)
                    texts.append(re.sub(r"[`*_]", "", text).lower())
                    s = slug(text)
                    n = seen.get(s, 0)
                    seen[s] = n + 1
                    slugs.add(s if n == 0 else "%s-%d" % (s, n))
        _headings[path] = (texts, slugs)
    return _headings[path]


def tasks():
    names = set()
    tf = os.path.join(ROOT, "Taskfile.yml")
    if os.path.exists(tf):
        in_tasks = False
        with open(tf, encoding="utf-8") as fh:
            for line in fh:
                if re.match(r"^tasks:\s*$", line):
                    in_tasks = True
                elif re.match(r"^\S", line):
                    in_tasks = False
                elif in_tasks:
                    m = re.match(r"^  ([A-Za-z0-9_:-]+):\s*$", line)
                    if m:
                        names.add(m.group(1))
    targets = set()
    mf = os.path.join(ROOT, "Makefile")
    if os.path.exists(mf):
        with open(mf, encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r"^([a-z][a-z0-9-]*)\s*:", line)
                if m:
                    targets.add(m.group(1))
    return names, targets


def main():
    problems = []
    ops_links, runbooks = set(), []
    task_names, make_targets = tasks()
    for group in ("addons", "charts"):
        gdir = os.path.join(ROOT, group)
        if os.path.isdir(gdir):
            for entry in sorted(os.listdir(gdir)):
                edir = os.path.join(gdir, entry)
                if not entry.startswith(".") and os.path.isdir(edir):
                    readme = os.path.join(edir, "README.md")
                    if not os.path.isfile(readme):
                        problems.append("%s: missing README.md" % os.path.relpath(readme, ROOT).replace("\\", "/"))
    for path in md_files():
        rel = os.path.relpath(path, ROOT)
        rel_posix = rel.replace("\\", "/")
        is_ops = rel_posix == "docs/operations.md" or rel_posix.startswith("docs/runbooks/")
        if rel_posix.startswith("docs/runbooks/"):
            runbooks.append(rel_posix)
            htexts = set(headings(path)[0])
            for sec in RUNBOOK_SECTIONS:
                if sec not in htexts:
                    problems.append('%s: runbook missing section "%s"' % (rel, sec))
        base = os.path.dirname(path)
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
        if CHART_README.match(rel_posix):
            htexts = set(headings(path)[0])
            for sec in CHART_README_SECTIONS:
                if sec not in htexts:
                    problems.append('%s: README missing section "%s"' % (rel, sec))
            body = lines[:-1] if lines and lines[-1] == "" else lines
            nlines = sum(1 for l in body if not l.lstrip().startswith("|"))
            if nlines > CHART_README_MAX_LINES:
                problems.append("%s: README is %d lines (max %d)" % (rel, nlines, CHART_README_MAX_LINES))
            vfile = os.path.join(base, "values.yaml")
            if os.path.isfile(vfile):
                with open(vfile, encoding="utf-8") as vfh:
                    vdescs = [m.group(1).strip() for m in re.finditer(r"^\s*#\s*--\s+(.+)$", vfh.read(), re.M)]
                raw = "\n".join(lines)
                if any(d not in raw for d in vdescs):
                    problems.append("%s: stale README.md (out of sync with values.yaml; run helm-docs)" % rel_posix)
        fence = False
        for no, line in enumerate(lines, 1):
            where = "%s:%d" % (rel, no)
            if line.lstrip().startswith(("```", "~~~")):
                fence = not fence
                continue
            spans = [m.group(2) for m in CODE_SPAN.finditer(line)] if not fence else [line]
            # commands
            for text in spans:
                if FORBIDDEN_CTX.search(text):
                    problems.append("%s: forbidden kube context `koorikla`" % where)
                for m in CMD.finditer(text):
                    kind, name = m.groups()
                    if kind == "task" and task_names and name not in task_names and not name.startswith("-"):
                        problems.append("%s: `task %s` is not a Taskfile task" % (where, name))
                    if kind == "make" and make_targets and name not in make_targets:
                        problems.append("%s: `make %s` is not a Makefile target" % (where, name))
            if fence:
                if is_ops and not line.lstrip().startswith("#") and KUBECTL_CMD.search(line) \
                        and "--context" not in line and "--kubeconfig" not in line:
                    problems.append("%s: `kubectl` in operations/runbook must pass --context or --kubeconfig" % where)
                continue
            prose = CODE_SPAN.sub(lambda m: "`" + "x" * len(m.group(2)) + "`", line)
            # links
            for target in [m.group(1) for m in LINK.finditer(prose)] + [m.group(1) for m in HTML_LINK.finditer(line)]:
                if re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I):
                    continue
                file_part, _, frag = target.partition("#")
                dest = path if not file_part else os.path.normpath(os.path.join(base, file_part))
                if not os.path.exists(dest):
                    problems.append("%s: link target %s does not exist" % (where, target))
                else:
                    if rel_posix == "docs/operations.md":
                        ops_links.add(os.path.relpath(dest, ROOT).replace("\\", "/"))
                    if frag and dest.endswith(".md") and frag.lower() not in headings(dest)[1]:
                        problems.append("%s: link %s: no heading #%s in %s" % (where, target, frag, os.path.relpath(dest, ROOT)))
            # "doc.md "Section"" cross-references
            for m in SECTION_REF.finditer(line):
                doc, section = m.groups()
                cands = [os.path.normpath(os.path.join(base, doc)), os.path.join(ROOT, doc), os.path.join(ROOT, "docs", doc)]
                dest = next((c for c in cands if os.path.isfile(c)), None)
                if dest is None:
                    problems.append("%s: %s does not exist" % (where, doc))
                    continue
                want = section.lower()
                if not any(t.startswith(want) or want in t for t in headings(dest)[0]):
                    problems.append('%s: %s has no section "%s"' % (where, os.path.relpath(dest, ROOT), section))
            # repo paths in code spans
            for text in spans:
                for tok in re.split(r"[\s,;()]+", text):
                    tok = tok.strip("'\".:")
                    if not tok.startswith(PATH_ROOTS) or PLACEHOLDER.search(tok):
                        continue
                    tok = re.sub(r":\d+$", "", tok)
                    if not os.path.exists(os.path.join(ROOT, tok)):
                        problems.append("%s: path %s does not exist" % (where, tok))
            # bare docs/*.md mentions in prose
            bare = HTML_LINK.sub("", LINK.sub("", prose))
            for m in re.finditer(r"(?<![\w/.-])(docs/[\w/-]+\.md)", bare):
                if not os.path.exists(os.path.join(ROOT, m.group(1))):
                    problems.append("%s: %s does not exist" % (where, m.group(1)))
    if os.path.isfile(os.path.join(ROOT, "docs", "operations.md")):
        for rb in runbooks:
            if rb not in ops_links:
                problems.append("docs/operations.md: runbook %s is not linked" % rb)
    for p in problems:
        print("  FAIL " + p)
    if problems:
        print("docs check: %d problem(s)" % len(problems))
        return 1
    print("docs check OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
