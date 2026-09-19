#!/usr/bin/env python3
"""Prepare the reviewed Blip source offline, without modifying an existing tree."""
import argparse
import hashlib
import json
from pathlib import Path
import tarfile
import tempfile
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent


def verify(path, expected, label):
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise ValueError(f"{label} checksum mismatch")


def prepare(output):
    pin = json.loads((ROOT / "pin.json").read_text())
    archive = ROOT / "upstream/blip.tar.gz"
    verify(archive, pin["sourceSha256"], "source")
    patch = ROOT / "transport.patch"
    verify(patch, pin["patchSha256"], "patch")
    verify(ROOT / "upstream/LICENSE", pin["licenseSha256"], "license")
    if output.exists() or output.is_symlink():
        raise ValueError("output already exists")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as temporary:
        staging = Path(temporary)
        with tarfile.open(archive) as source:
            source.extractall(staging, filter="data")
        tree = staging / f"blip-{pin['commit']}"
        verify(tree / "LICENSE", pin["licenseSha256"], "license")
        result = subprocess.run(
            ["patch", "--batch", "--fuzz=0", "-p1", "-i", str(patch)],
            cwd=tree, capture_output=True, text=True,
        )
        if result.returncode or "offset" in result.stdout or "fuzz" in result.stdout:
            raise ValueError("patch did not apply exactly")
        shutil.copyfile(ROOT / "blip-link.ts", tree / "bridge/linux/blip-link.ts")
        provenance = {**pin, "adapterSha256": hashlib.sha256((ROOT / "blip-link.ts").read_bytes()).hexdigest()}
        (tree / "TRY-OMARCHY-PROVENANCE.json").write_text(json.dumps(provenance, indent=2) + "\n")
        tree.rename(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        prepare(args.output)
    except (OSError, ValueError, tarfile.TarError) as error:
        parser.exit(1, f"blip prepare: {error}\n")
