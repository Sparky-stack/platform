#!/usr/bin/env python3
"""Render a golden-path Backstage template offline, the way its steps would (hack/tests/test_project_templates.sh).

Usage: render_template.py <template dir> <template.yaml as JSON> <parameters JSON> <out dir>

Reads the template (converted to JSON by yq: stdlib only here), resolves every `fetch:template` step's `values` from
the sample parameters, and renders its skeleton into <out dir>/<targetPath> - the repository content (`targetPath`
unset) or the platform PR (`./platform`). Steps with `if:` run when the parameter they name is true.

Deliberately a subset of the scaffolder's nunjucks: skeletons may only use `${{ values.<key> }}` with an optional
`| dump` (JSON string) or `| lower` filter, in file contents and path names. Anything else - another expression, a
`{% %}` block or a `{# #}` comment (both start nunjucks syntax and break `fetch:template` on code that happens to
contain them) - fails the render, so a skeleton cannot rely on templating this test does not verify. Files matched by
the step's `copyWithoutTemplating` are copied verbatim and must not contain `${{ values.`.
Step inputs (outside skeletons) may use `${{ parameters.<key> }}` with `| lower`.
"""
import fnmatch
import json
import os
import re
import shutil
import sys

VALUE = re.compile(r"\$\{\{\s*values\.([A-Za-z_][A-Za-z0-9_]*)\s*(?:\|\s*(dump|lower)\s*)?\}\}")
PARAM = re.compile(r"\$\{\{\s*parameters\.([A-Za-z_][A-Za-z0-9_]*)\s*(?:\|\s*(lower)\s*)?\}\}")
FORBIDDEN = ("${{", "{%", "{#")


class RenderError(Exception):
    pass


def apply(match, values, where):
    key, flt = match.group(1), match.group(2)
    if key not in values:
        raise RenderError(f"{where}: unknown value {key!r} (step values: {sorted(values)})")
    v = values[key]
    if flt == "dump":
        return json.dumps(v)
    s = v if isinstance(v, str) else json.dumps(v)
    return s.lower() if flt == "lower" else s


def render_text(text, values, where):
    out = VALUE.sub(lambda m: apply(m, values, where), text)
    for token in FORBIDDEN:
        if token in out:
            line = out[: out.index(token)].count("\n") + 1
            raise RenderError(f"{where}:{line}: unsupported template syntax {token!r} after rendering")
    return out


def resolve_param(value, params, where):
    """A step input: a whole-string `${{ parameters.x }}` keeps its type, otherwise string substitution."""
    if not isinstance(value, str):
        return value
    m = PARAM.fullmatch(value.strip())
    if m:
        v = params[m.group(1)]
        return v.lower() if m.group(2) else v

    def sub(m):
        if m.group(1) not in params:
            raise RenderError(f"{where}: unknown parameter {m.group(1)!r}")
        v = str(params[m.group(1)])
        return v.lower() if m.group(2) else v

    out = PARAM.sub(sub, value)
    if "${{" in out:
        raise RenderError(f"{where}: unsupported expression in step input: {value!r}")
    return out


def render_skeleton(src, dst, values, verbatim, where):
    if not os.path.isdir(src):
        raise RenderError(f"{where}: skeleton {src} does not exist")
    count = 0
    for d, dirs, files in os.walk(src):
        dirs.sort()
        rel_dir = os.path.relpath(d, src)
        for f in sorted(files):
            rel = f if rel_dir == "." else os.path.join(rel_dir, f).replace(os.sep, "/")
            rel_out = render_text(rel, values, f"{where} path {rel}")
            out = os.path.join(dst, *rel_out.split("/"))
            os.makedirs(os.path.dirname(out), exist_ok=True)
            try:
                with open(os.path.join(d, f), encoding="utf-8", newline="") as fh:
                    text = fh.read()
            except UnicodeDecodeError:  # binary: fetch:template copies those as they are
                shutil.copyfile(os.path.join(d, f), out)
                count += 1
                continue
            if any(fnmatch.fnmatchcase(rel, g) for g in verbatim):
                if VALUE.search(text):
                    raise RenderError(f"{where} {rel}: copied without templating but uses ${{{{ values.* }}}}")
                shutil.copyfile(os.path.join(d, f), out)
            else:
                with open(out, "w", encoding="utf-8", newline="") as fh:
                    fh.write(render_text(text, values, f"{where} {rel}"))
            count += 1
    return count


def main():
    base, tpl_json, params_json, out_dir = sys.argv[1:5]
    with open(tpl_json, encoding="utf-8") as fh:
        tpl = json.load(fh)
    with open(params_json, encoding="utf-8") as fh:
        params = json.load(fh)
    for step in tpl["spec"]["steps"]:
        if step["action"] != "fetch:template":
            continue
        cond = step.get("if")
        if cond is not None and not resolve_param(cond, params, step["id"]):
            print(f"  skip {step['id']} (if: {cond})")
            continue
        inp = step["input"]
        values = {k: resolve_param(v, params, f"{step['id']}.values.{k}") for k, v in inp.get("values", {}).items()}
        target = os.path.normpath(os.path.join(out_dir, inp.get("targetPath", ".")))
        src = os.path.normpath(os.path.join(base, inp["url"]))
        n = render_skeleton(src, target, values, inp.get("copyWithoutTemplating", []), step["id"])
        print(f"  rendered {step['id']}: {n} file(s) from {os.path.relpath(src, base)}")


if __name__ == "__main__":
    try:
        main()
    except (RenderError, KeyError) as e:
        sys.exit(f"render_template: {e}")
