#!/bin/sh
# Import a verified ARM64 Thunderboot appliance into an application bundle.
#
# Usage:
#   scripts/import-thunderboot-appliance.sh SOURCE DESTINATION
#
# SOURCE is normally ../thundersnap/thunderboot-out during development or a
# release-only artifact staging directory. Only the immutable boot inputs are
# copied; the .tar.zst transport archive is deliberately not shipped.
set -eu

source_dir=${1:?usage: $0 SOURCE DESTINATION}
destination=${2:?usage: $0 SOURCE DESTINATION}

python3 - "$source_dir" "$destination" <<'PY'
import hashlib
import json
import os
import pathlib
import shutil
import sys
import tempfile

source = pathlib.Path(sys.argv[1]).resolve()
destination = pathlib.Path(sys.argv[2]).resolve()
manifest_path = source / "manifest.json"
if not manifest_path.is_file():
    raise SystemExit(f"missing appliance manifest: {manifest_path}")
manifest = json.loads(manifest_path.read_text())
if manifest.get("schemaVersion") != 1:
    raise SystemExit("unsupported Thunderboot manifest schema")
if manifest.get("architecture") != "arm64" or manifest.get("operatingSystem") != "linux":
    raise SystemExit("Thunderboot artifact is not a Linux/ARM64 appliance")

files = ("Image", "initramfs.cpio", "manifest.json")
for name in files:
    path = source / name
    expected = manifest.get("artifacts", {}).get(name)
    if name == "manifest.json":
        if not path.is_file():
            raise SystemExit(f"manifest/file mismatch for {name}")
        continue
    if not path.is_file() or not expected:
        raise SystemExit(f"manifest/file mismatch for {name}")
    size = path.stat().st_size
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if size != expected.get("size") or digest != expected.get("sha256"):
        raise SystemExit(f"hash or size mismatch for {name}")

# Stage the complete unit then replace the old one. This prevents an app build
# from ever seeing a new kernel with an old initramfs (or vice versa).
temporary = pathlib.Path(tempfile.mkdtemp(prefix="Thunderboot.", dir=destination.parent))
try:
    for name in files:
        shutil.copy2(source / name, temporary / name)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        shutil.rmtree(destination)
    temporary.rename(destination)
finally:
    if temporary.exists():
        shutil.rmtree(temporary)
PY
