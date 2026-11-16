#!/usr/bin/env python3
"""Validate deploy/openchoreo/ against the OpenChoreo 1.3.3 CRD schemas (hack/crd-schemas/).

Strict like `kubeconform -strict`: unknown fields are errors (the API server would silently prune them). Also checks
the app repo contract of koorikla/platform (docs/openchoreo.md "App repo contract"): one Component, owner refs point at
it and its project, no metadata.namespace, ReleaseBinding names are <component>-<environment>.
Needs: pyyaml, jsonschema (CI: `uv run --with pyyaml --with jsonschema python3 hack/validate-manifests.py`).
"""
import json
import pathlib
import sys

import jsonschema
import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCHEMAS = ROOT / "hack" / "crd-schemas"
MANIFESTS = ROOT / "deploy" / "openchoreo"


def strict(schema):
    """Disallow unknown fields wherever the CRD does not preserve them."""
    if isinstance(schema, dict):
        if (
            schema.get("type") == "object"
            and "properties" in schema
            and "additionalProperties" not in schema
            and not schema.get("x-kubernetes-preserve-unknown-fields")
        ):
            schema["additionalProperties"] = False
        for v in schema.values():
            strict(v)
    elif isinstance(schema, list):
        for v in schema:
            strict(v)
    return schema


def load_schema(kind, api_version):
    group, version = api_version.split("/")
    path = SCHEMAS / f"{kind.lower()}-{group}-{version}.json"
    if not path.exists():
        return None
    schema = strict(json.loads(path.read_text()))
    # metadata is not described by CRD schemas; allow it.
    schema.setdefault("properties", {})["metadata"] = {"type": "object"}
    return schema


def main() -> int:
    errors = []
    docs = []
    for path in sorted(MANIFESTS.rglob("*.yaml")):
        rel = path.relative_to(ROOT)
        for i, doc in enumerate(yaml.safe_load_all(path.read_text())):
            if doc:
                docs.append((f"{rel}[{i}]", doc))

    components = [d for _, d in docs if d.get("kind") == "Component"]
    if len(components) != 1:
        print(f"ERROR deploy/openchoreo must hold exactly one Component (found {len(components)})")
        return 1
    component = components[0]["metadata"]["name"]
    project = components[0].get("spec", {}).get("owner", {}).get("projectName")

    seen = {}
    for where, doc in docs:
        kind, api = doc.get("kind"), doc.get("apiVersion", "")
        schema = load_schema(kind, api) if "/" in api else None
        if schema is None:
            errors.append(f"{where}: no schema for {api} {kind}")
            continue
        for e in jsonschema.Draft7Validator(schema).iter_errors(doc):
            loc = ".".join(str(p) for p in e.absolute_path)
            errors.append(f"{where}: {loc}: {e.message}")
        name = doc.get("metadata", {}).get("name")
        if not name:
            errors.append(f"{where}: metadata.name missing")
        if "namespace" in doc.get("metadata", {}):
            errors.append(f"{where}: metadata.namespace must be unset (Argo CD sets it)")
        if (kind, name) in seen:
            errors.append(f"{where}: duplicate {kind}/{name} (also in {seen[(kind, name)]})")
        seen[(kind, name)] = where

        owner = doc.get("spec", {}).get("owner", {})
        if owner.get("projectName") != project:
            errors.append(f"{where}: spec.owner.projectName must be {project!r}")
        if kind in ("Workload", "ReleaseBinding") and owner.get("componentName") != component:
            errors.append(f"{where}: spec.owner.componentName must be {component!r}")
        if kind == "ReleaseBinding":
            env = doc["spec"].get("environment")
            if name != f"{component}-{env}":
                errors.append(f"{where}: ReleaseBinding name must be {component}-{env}")

    kinds = {k for k, _ in seen}
    for required in ("Component", "Workload", "ReleaseBinding"):
        if required not in kinds:
            errors.append(f"missing a {required}")

    for e in errors:
        print(f"ERROR {e}")
    print(f"validated {len(seen)} objects, {len(errors)} error(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
