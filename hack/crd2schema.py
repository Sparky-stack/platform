#!/usr/bin/env python3
"""Convert CRD YAML files into kubeconform JSON schemas (stdlib + yq, no PyYAML needed)."""
import json
import pathlib
import subprocess
import sys


def main() -> None:
    if len(sys.argv) < 3:
        print("usage: crd2schema.py <out-dir> <crd.yaml>...", file=sys.stderr)
        sys.exit(2)

    out = pathlib.Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    dec = json.JSONDecoder()
    count = 0

    for path in sys.argv[2:]:
        p = pathlib.Path(path)
        if not p.is_file() or p.stat().st_size == 0:
            continue
        proc = subprocess.run(["yq", "-o=json", ".", str(p)], capture_output=True, text=True, check=True)
        s = proc.stdout
        idx = 0
        n = len(s)
        while idx < n:
            while idx < n and s[idx].isspace():
                idx += 1
            if idx >= n:
                break
            doc, idx = dec.raw_decode(s, idx)
            if not isinstance(doc, dict) or doc.get("kind") != "CustomResourceDefinition":
                continue
            spec = doc.get("spec", {})
            group = spec.get("group")
            kind = spec.get("names", {}).get("kind", "").lower()
            if not group or not kind:
                continue
            for v in spec.get("versions", []):
                ver = v.get("name")
                schema = v.get("schema", {}).get("openAPIV3Schema")
                if not ver or not schema:
                    continue
                schema = dict(schema)
                schema.setdefault("$schema", "http://json-schema.org/draft-07/schema#")
                (out / group).mkdir(parents=True, exist_ok=True)
                payload = json.dumps(schema)
                (out / group / f"{kind}_{ver}.json").write_text(payload)
                (out / f"{kind}_{group}_{ver}.json").write_text(payload)
                count += 1

    print(f"generated {count} CRD schemas in {out}")


if __name__ == "__main__":
    main()
