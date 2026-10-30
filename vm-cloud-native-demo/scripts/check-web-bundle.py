#!/usr/bin/env python3
"""Check that the web VM would boot with exactly the bundle we built.

Reads a rendered chart (`helm template ... > rendered.yaml`), finds the base64
cloud-init payload for /opt/orders/web.tar.gz, decodes it, and compares every
member with frontend/dist. Fails when the chart carries a stale or truncated
bundle, which is otherwise only visible after a slow VM boot.
"""
import base64
import hashlib
import io
import pathlib
import sys
import tarfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
DIST = ROOT / "frontend" / "dist"


def extract_payload(rendered: str) -> bytes:
    marker = "- path: /opt/orders/web.tar.gz"
    start = rendered.find(marker)
    if start < 0:
        raise SystemExit("rendered chart has no /opt/orders/web.tar.gz write_files entry")
    content = rendered.find("content: |", start)
    if content < 0:
        raise SystemExit("web bundle write_files entry has no content block")
    lines = []
    for line in rendered[content:].splitlines()[1:]:
        if not line.strip():
            continue
        if not line.startswith(" " * 10):
            break
        lines.append(line.strip())
    if not lines:
        raise SystemExit("web bundle content block is empty")
    return base64.b64decode("".join(lines))


def main() -> int:
    rendered_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/vm-cloud-native-rendered.yaml"
    rendered = pathlib.Path(rendered_path).read_text()
    payload = extract_payload(rendered)

    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as archive:
        members = {member.name.lstrip("./"): member for member in archive.getmembers() if member.isfile()}
        problems = []
        for name, member in sorted(members.items()):
            local = DIST / name
            if not local.is_file():
                problems.append(f"bundle has {name}, dist does not")
                continue
            packed = archive.extractfile(member)
            assert packed is not None
            if hashlib.sha256(packed.read()).digest() != hashlib.sha256(local.read_bytes()).digest():
                problems.append(f"{name} differs between the chart and frontend/dist")
        for local in sorted(DIST.rglob("*")):
            if local.is_file() and str(local.relative_to(DIST)) not in members:
                problems.append(f"dist has {local.relative_to(DIST)}, bundle does not")

    encoded = len(base64.b64encode(payload))
    print(f"web bundle: {len(members)} files, {len(payload)} bytes packed, {encoded} bytes base64")
    if encoded > 900_000:
        problems.append(f"encoded bundle is {encoded} bytes; the cloud-init Secret limit is 1 MiB")
    for problem in problems:
        print(f"FAIL: {problem}", file=sys.stderr)
    if problems:
        return 1
    print(f"web bundle matches {DIST.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
