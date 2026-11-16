#!/usr/bin/env python3
"""Extract JSON schemas for the OpenChoreo kinds this repo uses from CRD YAMLs.

Usage: hack/gen-crd-schemas.py <dir-with-openchoreo-crds>

The CRDs come from the OpenChoreo control-plane Helm chart (crds/) at the
version the platform runs (1.3.3):
  helm pull oci://ghcr.io/openchoreo/helm-charts/openchoreo-control-plane \
    --version 1.3.3 --untar
  hack/gen-crd-schemas.py openchoreo-control-plane/crds
"""

import json
import pathlib
import sys

import yaml

KINDS = {
    "openchoreo.dev_components.yaml": "Component",
    "openchoreo.dev_workloads.yaml": "Workload",
    "openchoreo.dev_releasebindings.yaml": "ReleaseBinding",
}
OUT = pathlib.Path(__file__).parent / "crd-schemas"


def main() -> None:
    src = pathlib.Path(sys.argv[1])
    OUT.mkdir(exist_ok=True)
    for fname, kind in KINDS.items():
        crd = yaml.safe_load((src / fname).read_text())
        if crd["spec"]["names"]["kind"] != kind:
            sys.exit(f"{fname}: kind {crd['spec']['names']['kind']}, expected {kind}")
        group = crd["spec"]["group"]
        for v in crd["spec"]["versions"]:
            if not v.get("served"):
                continue
            out = OUT / f"{kind.lower()}-{group}-{v['name']}.json"
            out.write_text(json.dumps(v["schema"]["openAPIV3Schema"], indent=1, sort_keys=True) + "\n")
            print(f"wrote {out}")


if __name__ == "__main__":
    main()
