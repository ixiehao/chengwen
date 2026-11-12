"""Read Mach-O load commands without executing either architecture."""
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import zipfile


def audit_native_contents(application, version):
    """Reject an accidental legacy runtime even when the outer App is Swift."""
    application = Path(application)
    resources = application / "Contents/Resources"
    expected_resources = {"AppIcon.icns", "LICENSE", "ChengWen_ChengWen.bundle", "THIRD_PARTY", "Release.json", f"澄闻-{version}-source.zip"}
    assert {p.name for p in resources.iterdir()} == expected_resources, "Unexpected resources in pure Swift application"
    assert {p.name for p in (application / "Contents/MacOS").iterdir()} == {"ChengWen"}, "Extra executable in application"
    forbidden = {"engine", "python", "spotdl", "you_get", "pyside6", "shiboken6", "pyobjc"}
    for path in (application / "Contents").rglob("*"):
        relative = path.relative_to(application)
        assert not any(part.lower() in forbidden or part.lower().startswith("python3") or part.endswith(".dSYM") for part in relative.parts), f"Legacy runtime/debug artifact: {relative}"
        assert path.suffix not in {".py", ".pyc", ".pyo", ".so", ".dylib"}, f"Bundled non-native runtime: {relative}"
        if path.is_symlink():
            assert path.resolve().is_relative_to(application.resolve()), f"External App symlink: {relative}"
    manifest = json.loads((resources / "Release.json").read_text())
    assert manifest.get("pure_swift") is True and manifest.get("python_runtime") is False and manifest.get("backend") == "Swift", "Wrong native release manifest"
    assert manifest.get("version") == version
    project_license = (resources / "LICENSE").read_text()
    assert all(text in project_license for text in ("MIT License", "Copyright", "Permission is hereby granted")), "Project license/copyright notice missing"
    notices = resources / "THIRD_PARTY"
    expected_notices = {"README.md", "dependencies.json", "tabler-icons-LICENSE.txt", "TuneWeave-MIT.txt", "Listen1-MIT.txt"}
    assert {p.name for p in notices.iterdir()} == expected_notices, "Unexpected or missing license materials"
    for name in ("tabler-icons-LICENSE.txt", "TuneWeave-MIT.txt", "Listen1-MIT.txt"):
        assert "MIT License" in (notices / name).read_text(), f"Missing MIT license: {name}"
    dependencies = json.loads((notices / "dependencies.json").read_text())
    assert isinstance(dependencies, list) and len(dependencies) == 3, "Unexpected native dependency manifest"
    assert all(record.get("license") == "MIT" for record in dependencies), "Unexpected license in native dependency manifest"
    assert all("pypi" not in record for record in dependencies), "Python package manifest remained in application"
    bundle = resources / "ChengWen_ChengWen.bundle"
    # SwiftPM produces a flat resource bundle with some toolchains and a
    # macOS Contents/Resources bundle with Xcode's build system. AppVersion
    # uses NSBundle.resourceURL; audit both supported physical layouts.
    versions = [p for p in (bundle / "Resources/Version.json", bundle / "Contents/Resources/Resources/Version.json") if p.is_file()]
    assert len(versions) == 1, "Missing or ambiguous bundled version resource"
    resource_version = json.loads(versions[0].read_text())
    assert resource_version.get("version") == version and str(resource_version.get("build")) == str(manifest.get("build")), "Resource/manifest version mismatch"
    pngs = list(bundle.rglob("*.png"))
    assert pngs and any(p.name == "LICENSE" and p.parent.name == "Tabler" and "MIT License" in p.read_text() for p in bundle.rglob("LICENSE")), "Missing Tabler resources/license"
    source = resources / f"澄闻-{version}-source.zip"
    with zipfile.ZipFile(source) as archive:
        names = archive.namelist()
        assert "澄闻/Package.swift" in names and any(name.startswith("澄闻/Sources/") and name.endswith(".swift") for name in names), "Incomplete native source archive"
        required_public = {"LICENSE", "CONTRIBUTING.md", "PRIVACY.md", "SECURITY.md", "CHANGELOG.md", "dev-requirements.txt", ".github/workflows/ci.yml", "Tests/test_packaging.py", "scripts/validate.py", "scripts/export_source.py", "scripts/verify_public_source.py"}
        assert {"澄闻/" + name for name in required_public}.issubset(names), "Missing public-source license or verification entry points"
        assert archive.read("澄闻/LICENSE").decode() == project_license, "Source and App project licenses differ"
        for name in names:
            parts = Path(name).parts
            assert not Path(name).is_absolute() and ".." not in parts, "Unsafe archive path"
            assert not any(part in {"维护记录", ".local", "cookies.txt", "YOUGET_PROBE.md", "youget-probe"} for part in parts), "Private or legacy materials in current source archive"
            assert not name.startswith(("澄闻/chengwen/", "澄闻/.venv/", "澄闻/requirements", "澄闻/uv.lock")), "Legacy engine source in native package"
            assert not any(part in {"__pycache__", ".build-release", "build", "dist"} or part.startswith(".build-") or part.endswith(".dSYM") for part in parts), "Build cache in source archive"
    return {"pure_swift": True, "python_runtime": False, "tabler_pngs": len(pngs), "source_archive_bytes": source.stat().st_size}


def slices(data):
    if data[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        wide = data[3] == 0xbf
        count = struct.unpack_from(">I", data, 4)[0]
        for index in range(count):
            entry = 8 + index * (32 if wide else 20)
            offset = struct.unpack_from(">Q" if wide else ">I", data, entry + 8)[0]
            yield from slices(data[offset:])
        return
    if data[:4] != b"\xcf\xfa\xed\xfe":
        return
    cpu, = struct.unpack_from("<I", data, 4)
    commands, = struct.unpack_from("<I", data, 16)
    position = 32
    minimum = None
    for _ in range(commands):
        command, size = struct.unpack_from("<II", data, position)
        if command == 0x32:
            target, version = struct.unpack_from("<II", data, position + 8)
            if target == 1:
                minimum = (version >> 16, (version >> 8) & 255, version & 255)
        elif command == 0x24:
            version, = struct.unpack_from("<I", data, position + 8)
            minimum = (version >> 16, (version >> 8) & 255, version & 255)
        if size < 8:
            raise ValueError("Invalid Mach-O command")
        position += size
    yield {"architecture": {0x1000007: "x86_64", 0x100000c: "arm64"}.get(cpu, str(cpu)), "minimum": minimum}


def verify(application, architectures=("arm64", "x86_64")):
    application = Path(application)
    info = plistlib.loads((application / "Contents/Info.plist").read_bytes())
    assert info["LSMinimumSystemVersion"] == "12.0"
    assert info["CFBundleDisplayName"] == "澄闻" and info["CFBundleName"] == "澄闻", "Stale product name in installer"
    assert info["CFBundleExecutable"] == "ChengWen", "Wrong renamed executable"
    # A rebrand must not silently create another app/Keychain authorization identity.
    assert info["CFBundleIdentifier"] == "local.vmdown.desktop", "Upgrade application identity changed"
    launcher = application / "Contents/MacOS/ChengWen"
    expected = set(architectures)
    assert {s["architecture"] for s in slices(launcher.read_bytes())} == expected, "Executable architecture mismatch"
    failures, count, highest = [], 0, (0, 0, 0)
    for path in (application / "Contents").rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open("rb") as stream:
            magic = stream.read(4)
        if magic not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
            continue
        count += 1
        for item in slices(path.read_bytes()):
            if item["minimum"] is None or item["minimum"] > (12, 0, 0):
                failures.append({"file": str(path.relative_to(application)), **item})
            highest = max(highest, item["minimum"] or (0, 0, 0))
        if {item["architecture"] for item in slices(path.read_bytes())} != expected:
            failures.append({"file": str(path.relative_to(application)), "architecture_mismatch": True})
    assert not failures, json.dumps(failures, indent=2)
    assert count == 1, "Pure Swift release should contain only its native executable"
    native = audit_native_contents(application, info["CFBundleShortVersionString"])
    manifest = json.loads((application / "Contents/Resources/Release.json").read_text())
    assert str(manifest.get("build")) == info["CFBundleVersion"], "Info.plist and release manifest build mismatch"
    libraries = [line.strip().split(" (", 1)[0] for line in subprocess.check_output(["/usr/bin/otool", "-L", str(launcher)], text=True).splitlines()[1:]]
    assert all(path.startswith(("/System/Library/", "/usr/lib/", "@rpath/libswift")) for path in libraries), libraries
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(application)], check=True)
    return {"version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"], "architectures": sorted(expected), "mach_o_files": count, "highest_minimum_macos": ".".join(map(str, highest)), "signature": "ad-hoc", "notarized": False, "linked_libraries": libraries, "build_environment": manifest.get("build_environment", {}), **native}


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("application")
    parser.add_argument("--architecture", choices=("arm64", "x86_64", "universal2"), default="universal2")
    arguments = parser.parse_args()
    expected = ("arm64", "x86_64") if arguments.architecture == "universal2" else (arguments.architecture,)
    print(json.dumps(verify(arguments.application, expected), indent=2))
