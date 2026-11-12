#!/usr/bin/env python3
"""Offline checks for the public allowlist, licenses and version metadata."""
from pathlib import Path
import json
import sys
import subprocess

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from macos.package_dmg import source_digest, validate_public_source


def verify_tracked_files(allowed, root=ROOT):
    try:
        top = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], cwd=root, stderr=subprocess.DEVNULL, text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        return {"git_tracking_check": "skipped: no project-root Git repository"}
    if Path(top).resolve() != root.resolve():
        return {"git_tracking_check": "skipped: project is not the Git top-level"}
    tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode("utf-8").split("\0")
    tracked = {name for name in tracked if name}
    unexpected = sorted(tracked - set(allowed))
    if unexpected:
        # Report paths only: never print possibly sensitive tracked contents.
        raise ValueError("Tracked paths outside the reviewed public allowlist: " + ", ".join(unexpected))
    return {"git_tracking_check": "passed", "tracked_files": len(tracked)}


def main():
    files = validate_public_source()
    assert "Tests/ChengWenTests/NativeDownloadsTableTests.swift" in files, "Case-sensitive test target missing"
    forbidden = ("维护记录/", ".local/", "docs/youget-probe/", "chengwen/", ".venv/", "dist/", ".build")
    assert not any(name.startswith(forbidden) or "YOUGET_PROBE" in name for name in files)
    dependencies = json.loads((ROOT / "THIRD_PARTY/dependencies.json").read_text())
    assert len(dependencies) == 3 and all(item.get("license") == "MIT" and item.get("version") for item in dependencies)
    for item in dependencies:
        notice = (ROOT / "THIRD_PARTY" / item["notice"]).read_text()
        assert "MIT License" in notice and "Copyright" in notice
    print(json.dumps({"public_files": len(files), "source_sha256": source_digest(), "license_version_checks": "passed", **verify_tracked_files(files)}, indent=2))


if __name__ == "__main__":
    main()
