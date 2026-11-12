#!/usr/bin/env python3
"""Export the reviewed public file set; never copy the entire workspace."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from macos.package_dmg import source_archive, source_digest, validate_public_source, no_existing
from macos.build_support import publish_artifacts, termination_handlers


def export_source(output):
    validate_public_source()
    output = Path(output).expanduser().absolute()
    checksum = output.with_name(output.name + ".sha256")
    manifest = output.with_name(output.name + ".manifest.json")
    no_existing(output, checksum, manifest)
    output.parent.mkdir(parents=True, exist_ok=True)
    expected = source_digest()
    # Prepare all three files before making any public output visible. Keep
    # staging on the destination volume so exclusive rename cannot cross disks.
    with tempfile.TemporaryDirectory(prefix=".chengwen-source-", dir=output.parent) as temporary:
        stage = Path(temporary)
        staged_archive, staged_checksum, staged_manifest = (stage / path.name for path in (output, checksum, manifest))
        recorded = source_archive(staged_archive)
        if expected != recorded or source_digest() != expected:
            raise RuntimeError("Source changed during export")
        digest = hashlib.sha256(staged_archive.read_bytes()).hexdigest()
        with staged_checksum.open("x") as stream:
            stream.write(digest + "  " + output.name + "\n")
        with zipfile.ZipFile(staged_archive) as archive:
            records = [{"path": entry.filename.removeprefix("澄闻/"), "mode": oct((entry.external_attr >> 16) & 0o777), "sha256": hashlib.sha256(archive.read(entry)).hexdigest()} for entry in archive.infolist()]
        with staged_manifest.open("x") as stream:
            json.dump({"source_sha256": expected, "archive_sha256": digest, "files": records}, stream, indent=2)
            stream.write("\n")
        if source_digest() != expected:
            raise RuntimeError("Source changed during export")
        publish_artifacts(zip((staged_archive, staged_checksum, staged_manifest), (output, checksum, manifest)))
    return {"archive": str(output), "files": len(records), "sha256": digest, "source_sha256": expected}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path, help="New .zip path outside the selected source tree")
    args = parser.parse_args()
    print(json.dumps(export_source(args.output), indent=2))


if __name__ == "__main__":
    with termination_handlers():
        main()
