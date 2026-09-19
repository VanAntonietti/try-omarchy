#!/usr/bin/env python3
"""Test the pinned adapter offline; --upstream also runs Blip's Linux fixtures."""
import argparse
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent


def run(*command, cwd=ROOT, env=None):
    subprocess.run(command, cwd=cwd, env=env, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", action="store_true")
    args = parser.parse_args()
    run("python3", "test_prepare.py")
    run("bun", "run", "typecheck")
    build = REPO / ".build"
    build.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="blip-test-", dir=build) as temporary:
        source = Path(temporary) / "source"
        run("python3", "prepare.py", "--output", str(source))
        env = {**os.environ, "BLIP_TEST_SOURCE": str(source), "TZ": "UTC"}
        run("bun", "test", "transport.test.ts", env=env)
        run("bash", "-n", "bridge/linux/blip-shim", "scripts/blip-setup", cwd=source)
        if args.upstream:
            run("bun", "test", cwd=source, env=env)
            # These are upstream's invented-data Mac bridge tests, not the tools.
            run("python3", "-m", "unittest", "discover", "-s", "bridge/mac", "-p", "*test*.py", cwd=source, env=env)
            run("shellcheck", "-S", "warning", "bridge/linux/blip-shim", "scripts/blip-setup", cwd=source)


if __name__ == "__main__":
    main()
