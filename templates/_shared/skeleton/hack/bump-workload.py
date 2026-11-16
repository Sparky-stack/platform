#!/usr/bin/env python3
"""Pin the image CI just published in deploy/openchoreo/workload.yaml (job `bump` of .github/workflows/ci.yaml).

NEW_IMAGE  <image>:<short sha>@sha256:<index digest>  (production admits only digest references)
NEW_COMMIT the commit the image was built from (Workload spec.source.commit; added on the first bump)
Line-based on purpose: keeps the file's comments and layout. Stdlib only.
"""
import os
import pathlib
import re
import sys

WORKLOAD = pathlib.Path(__file__).resolve().parent.parent / "deploy" / "openchoreo" / "workload.yaml"


def bump(text: str, image: str, commit: str) -> str:
    if not re.fullmatch(r"[^\s@]+:[^\s@]+@sha256:[0-9a-f]{64}", image):
        raise ValueError(f"NEW_IMAGE is not <image>:<tag>@sha256:<digest>: {image!r}")
    if not re.fullmatch(r"[0-9a-f]{7,40}", commit):
        raise ValueError(f"NEW_COMMIT is not a commit SHA: {commit!r}")
    text, n_image = re.subn(r"^([ \t]*image:[ \t]*).*$", rf"\g<1>{image}", text, count=1, flags=re.M)
    text, n_commit = re.subn(r'^([ \t]*commit:[ \t]*).*$', rf'\g<1>"{commit}"', text, count=1, flags=re.M)
    if n_commit == 0:
        # first bump: add the commit right after source.branch (same indentation)
        text, n_commit = re.subn(r'^([ \t]*)(branch:.*)$', rf'\1\2\n\1commit: "{commit}"', text, count=1, flags=re.M)
    if (n_image, n_commit) != (1, 1):
        raise ValueError(f"expected one image and one source.commit/branch line, got {n_image}, {n_commit}")
    return text


if __name__ == "__main__":
    try:
        WORKLOAD.write_text(bump(WORKLOAD.read_text(), os.environ["NEW_IMAGE"], os.environ["NEW_COMMIT"]))
    except (KeyError, ValueError) as e:
        sys.exit(f"bump-workload: {e}")
    print(f"bumped {WORKLOAD.name}")
