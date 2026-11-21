#!/usr/bin/env python3
"""Validate an app repo's OpenChoreo manifests (default deploy/openchoreo) before Argo CD applies them.

Usage: validate-manifests.py [dir]   (needs pyyaml + jsonschema; app-openchoreo-manifests.yaml runs it)
- Schema: every document against the platform's OpenChoreo CRD schemas (ci/schemas/openchoreo.dev, generated from the
  OpenChoreo version the platform pins). Strict like `kubeconform -strict`: the API server would prune unknown fields.
- Repo invariants OpenChoreo only reports after the sync: one project, no metadata.namespace (Argo CD sets it), owners
  name a Component of the repo, binding names <owner>-<env>, secretKeyRef -> SecretReference key, resource
  dependency -> Resource + a binding, ResourceReleaseBinding pin rules (docs/promotion.md "Resources").
GATED_ENVIRONMENTS (default "production"): environments the platform's auto-build pass never writes.
"""
import json
import os
import pathlib
import re
import sys

import jsonschema
import yaml

SCHEMAS = pathlib.Path(__file__).resolve().parents[2] / "schemas"
LATEST = "platform.koorikla.io/resource-release"
GATED = set(os.environ.get("GATED_ENVIRONMENTS", "production").split())
FIRST = os.environ.get("FIRST_ENVIRONMENT", "development")  # the autoDeploy environment


def strict(s):
    if isinstance(s, dict):
        if s.get("type") == "object" and "properties" in s and "additionalProperties" not in s \
                and not s.get("x-kubernetes-preserve-unknown-fields"):
            s["additionalProperties"] = False
        for v in s.values():
            strict(v)
    elif isinstance(s, list):
        for v in s:
            strict(v)
    return s


def schema_for(api, kind):
    group, _, version = api.rpartition("/")
    path = SCHEMAS / group / f"{kind.lower()}_{version}.json"
    if not group or not path.is_file():
        return None
    schema: dict = strict(json.loads(path.read_text()))
    schema.setdefault("properties", {})["metadata"] = {"type": "object"}  # not part of CRD schemas
    return schema


def load(root):
    docs = []
    for path in sorted(root.rglob("*.y*ml")):
        for i, doc in enumerate(yaml.safe_load_all(path.read_text())):
            if doc:
                docs.append((f"{path.relative_to(root)}[{i}]", doc))
    return docs


def check(docs):
    errors, seen = [], {}
    by_kind = lambda k: [(w, d) for w, d in docs if d.get("kind") == k]  # noqa: E731
    for where, doc in docs:
        kind, meta = doc.get("kind", ""), doc.get("metadata") or {}
        schema = schema_for(doc.get("apiVersion", ""), kind)
        if schema is None:
            errors.append(f"{where}: no platform schema for {doc.get('apiVersion')} {kind}")
            continue
        errors += [f"{where}: {'.'.join(map(str, e.absolute_path))}: {e.message}"
                   for e in jsonschema.Draft7Validator(schema).iter_errors(doc)]
        if "namespace" in meta:
            errors.append(f"{where}: metadata.namespace must be unset (Argo CD sets it)")
        key = (kind, meta.get("name"))
        if key in seen:
            errors.append(f"{where}: duplicate {kind}/{key[1]} (also {seen[key]})")
        seen[key] = where
    errors += relations(docs, by_kind)
    return errors


def relations(docs, by_kind):
    errors = []
    name = lambda d: (d.get("metadata") or {}).get("name")  # noqa: E731
    spec = lambda d: d.get("spec") or {}  # noqa: E731
    components = {name(d) for _, d in by_kind("Component")}
    projects = {(spec(d).get("owner") or {}).get("projectName") for _, d in docs if "owner" in spec(d)}
    if len(projects) > 1:
        errors.append(f"spec.owner.projectName differs between objects: {sorted(map(str, projects))}")
    for kind in ("Component", "Workload", "ReleaseBinding"):
        if not by_kind(kind):
            errors.append(f"missing a {kind}")
    for where, d in by_kind("Workload") + by_kind("ReleaseBinding"):
        if spec(d).get("owner", {}).get("componentName") not in components:
            errors.append(f"{where}: spec.owner.componentName names no Component in this repo")
    for where, d in by_kind("ReleaseBinding"):
        want = f"{spec(d).get('owner', {}).get('componentName')}-{spec(d).get('environment')}"
        if name(d) != want:
            errors.append(f"{where}: ReleaseBinding name must be {want}")
    secret_keys = {name(d): {x.get("secretKey") for x in spec(d).get("data", [])} for _, d in by_kind("SecretReference")}
    resources = {name(d) for _, d in by_kind("Resource")}
    bound = set()
    for where, d in by_kind("ResourceReleaseBinding"):
        res, env = spec(d).get("owner", {}).get("resourceName"), spec(d).get("environment")
        bound.add((res, env))
        pin = spec(d).get("resourceRelease")
        latest = ((d.get("metadata") or {}).get("annotations") or {}).get(LATEST) == "latest"
        if res not in resources:
            errors.append(f"{where}: spec.owner.resourceName {res!r} has no Resource")
        if name(d) != f"{res}-{env}":
            errors.append(f"{where}: ResourceReleaseBinding name must be {res}-{env}")
        if pin is not None and not re.fullmatch(rf"{re.escape(str(res))}-[0-9a-z]+", str(pin)):
            errors.append(f"{where}: spec.resourceRelease must pin a release {res}-<hash>")
        if env in GATED and (latest or pin is None):
            errors.append(f"{where}: {env} is gated: pin spec.resourceRelease, no {LATEST}: latest")
        elif pin is None and not latest:
            errors.append(f"{where}: set annotation {LATEST}: latest or pin spec.resourceRelease")
    for where, d in by_kind("Workload"):
        c = spec(d).get("container") or {}
        for item in c.get("env", []) + c.get("files", []):
            ref = (item.get("valueFrom") or {}).get("secretKeyRef")
            if ref and ref.get("key") not in secret_keys.get(ref.get("name"), set()):
                errors.append(f"{where}: secretKeyRef {ref.get('name')}/{ref.get('key')} has no SecretReference key")
        for dep in (spec(d).get("dependencies") or {}).get("resources", []):
            if dep.get("ref") not in resources:
                errors.append(f"{where}: dependencies.resources ref {dep.get('ref')!r} has no Resource")
            elif (dep.get("ref"), FIRST) not in bound:
                errors.append(f"{where}: Resource {dep.get('ref')!r} has no ResourceReleaseBinding for {FIRST}")
    return errors


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "deploy/openchoreo")
    docs = load(root)
    errors = check(docs) if docs else [f"{root}: no manifests"]
    for e in errors:
        print(f"::error::{e}" if os.environ.get("GITHUB_ACTIONS") else f"ERROR {e}")
    print(f"validated {len(docs)} objects in {root}, {len(errors)} error(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
