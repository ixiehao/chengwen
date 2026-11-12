#!/usr/bin/env python3
"""Explicit local/CI gate; never publishes, signs or changes user settings."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from macos.package_dmg import release_info, source_archive, validate_public_source, build_metadata
from macos.build_support import run_checked, termination_handlers


def preflight():
    if sys.platform != "darwin":
        raise RuntimeError("ChengWen builds and native tests require macOS")
    validate_public_source()
    missing = [name for name in ("swift", "xcrun", "uv", "ffmpeg", "ffprobe") if shutil.which(name) is None]
    if missing:
        raise RuntimeError("Missing validation tools: " + ", ".join(missing) + "; follow docs/DEVELOPMENT.md")
    run_checked(["xcrun", "--find", "swift"], stdout=subprocess.DEVNULL)
    ffmpeg, ffprobe = Path(shutil.which("ffmpeg")).resolve(), Path(shutil.which("ffprobe")).resolve()
    if ffmpeg.parent != ffprobe.parent:
        raise RuntimeError("Validation requires ffmpeg/ffprobe from the same installation")
    for path in (ffmpeg, ffprobe):
        run_checked([path, "-version"], stdout=subprocess.DEVNULL)
    return {"version": release_info()["CFBundleShortVersionString"], "preflight": "passed", "build_environment": build_metadata()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--preflight", action="store_true", help="Read-only tool/source checks, no build or dependency install")
    parser.add_argument("--skip-native-builds", action="store_true", help="Skip the two Release compile checks")
    args = parser.parse_args()
    print(json.dumps(preflight(), indent=2), flush=True)
    if args.preflight:
        return
    environment = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    run_checked([sys.executable, ROOT / "scripts/verify_public_source.py"], cwd=ROOT, env=environment)
    run_checked(["uv", "run", "--isolated", "--no-project", "--python", "3.12.13", "--with-requirements", ROOT / "dev-requirements.txt", "python", "-m", "pytest", "-q", "-p", "no:cacheprovider", ROOT / "Tests/test_packaging.py"], cwd=ROOT, env=environment)
    run_checked(["swift", "test", "--scratch-path", ROOT / ".build-native-validation"], cwd=ROOT)
    if not args.skip_native_builds:
        for architecture in ("arm64", "x86_64"):
            run_checked(["swift", "build", "-c", "release", "--arch", architecture, "--scratch-path", ROOT / (".build-validation-" + architecture), "-Xswiftc", "-warnings-as-errors"], cwd=ROOT)
    # Compile a relocated archive with a fresh scratch path. Parsing alone
    # would not catch missing assets, source files or workspace-only paths.
    with tempfile.TemporaryDirectory(prefix="chengwen-public-source-") as temporary:
        temporary = Path(temporary)
        archive = temporary / "source.zip"
        source_archive(archive)
        with zipfile.ZipFile(archive) as source:
            source.extractall(temporary / "extracted")
            # zipfile.extractall does not restore Unix executable bits. This
            # trusted archive is produced above from the reviewed file set.
            for entry in source.infolist():
                (temporary / "extracted" / entry.filename).chmod((entry.external_attr >> 16) & 0o777)
        run_checked(["swift", "build", "--scratch-path", temporary / "build"], cwd=temporary / "extracted/澄闻")
    print("Validation passed; no installer was published.")


if __name__ == "__main__":
    with termination_handlers():
        main()
