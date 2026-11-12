"""Build a pure Swift App and one self-contained DMG for each Mac CPU.

Python/dmgbuild are host build tools only; no interpreter or music package is
copied into the App. The source archive excludes the former Python engine.
"""
from __future__ import annotations
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile
import platform

try:
    from .native_package_smoke import smoke
    from .verify_app import verify
    from .build_support import PackagingLock, termination_handlers, run_checked, publish_artifacts
except ImportError:
    from native_package_smoke import smoke
    from verify_app import verify
    from build_support import PackagingLock, termination_handlers, run_checked, publish_artifacts

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".build-release"
NATIVE_BUILD_FILES = ("package_dmg.py", "build_support.py", "native_package_smoke.py", "verify_app.py", "dmg-settings.py", "verify-dmg-layout.py", "create-dmg-background.swift", "build-requirements.txt")
NOTICE_FILES = ("README.md", "dependencies.json", "tabler-icons-LICENSE.txt", "TuneWeave-MIT.txt", "Listen1-MIT.txt")
PUBLIC_ROOT_FILES = ("LICENSE", "README.md", "CONTRIBUTING.md", "PRIVACY.md", "SECURITY.md", "CHANGELOG.md", ".gitignore", "dev-requirements.txt", "Package.swift", "启动澄闻.command")
PUBLIC_DOCS = ("README.md", "DEVELOPMENT.md", "PACKAGING.md", "VALIDATION.md", "ACCOUNT_INTEGRATION.md", "AUDIO_TOOLS.md", "FAILURE_DIAGNOSTICS.md", "MONTEREY.md", "QA_DETAILS.md", "SOURCE_ADAPTERS.md", "UI_DESIGN.md", "BRANDING.md")
PUBLIC_SCRIPTS = ("validate.py", "export_source.py", "verify_public_source.py")
PUBLIC_GITHUB_FILES = (".github/workflows/ci.yml", ".github/ISSUE_TEMPLATE/config.yml")


def execute(arguments, **options):
    return run_checked(arguments, cwd=ROOT, **options)


def no_existing(*paths):
    for path in paths:
        if os.path.lexists(path):
            raise FileExistsError(f"Refusing to replace existing output: {path}")


def installer_paths(output, version, architecture):
    stem = f"chengwen-{version}-{architecture}"
    return output / f"{stem}.dmg", output / f"{stem}.dmg.sha256", output / f"{stem}-verification.json"


def source_files():
    """Buildable native source, text docs, build scripts and notices.

    Only the reviewed synthetic product screenshot and public validation
    summaries are included; private screenshots and history remain local.
    """
    names = list(PUBLIC_ROOT_FILES) + ["澄闻.app/Contents/Info.plist", "澄闻.app/Contents/MacOS/ChengWen", "澄闻.app/Contents/Resources/AppIcon.icns", *PUBLIC_GITHUB_FILES]
    names += ["macos/" + name for name in NATIVE_BUILD_FILES]
    names += ["THIRD_PARTY/" + name for name in NOTICE_FILES]
    names += ["scripts/" + name for name in PUBLIC_SCRIPTS]
    names += ["tools/build-brand-icon.swift", "tools/export-tabler.swift"]
    names += ["Assets/Brand/ChengWen.svg", "Assets/Brand/ChengWen.png"]
    names += ["docs/screenshot.png"]
    files = [ROOT / name for name in names if (ROOT / name).is_file()]
    for folder in ("Sources", "Tests"):
        files += [p for p in (ROOT / folder).rglob("*") if p.is_file() and "__pycache__" not in p.parts and p.name != ".DS_Store" and p.suffix not in {".pyc", ".pyo"}]
    files += [ROOT / "docs" / name for name in PUBLIC_DOCS if (ROOT / "docs" / name).is_file()]
    for name in ("native-070-anonymous.json", "native-080-anonymous.json"):
        public_validation = ROOT / "docs/backend-validation" / name
        if public_validation.is_file():
            files.append(public_validation)
    result = sorted(set(files))
    for path in result:
        if path.is_symlink() or not path.resolve().is_relative_to(ROOT.resolve()):
            raise ValueError("Public source cannot contain symlinks or external files: " + str(path.relative_to(ROOT)))
    return result


def release_info():
    info = plistlib.loads((ROOT / "澄闻.app/Contents/Info.plist").read_bytes())
    version = json.loads((ROOT / "Sources/ChengWen/Resources/Version.json").read_text())
    if str(version.get("version")) != info["CFBundleShortVersionString"] or str(version.get("build")) != info["CFBundleVersion"]:
        raise ValueError("Version.json and Info.plist version/build do not match")
    return info


def validate_public_source():
    required = set(PUBLIC_ROOT_FILES) | set(PUBLIC_GITHUB_FILES) | {"Sources/ChengWen/Resources/Version.json", "Tests/test_packaging.py", "docs/screenshot.png"}
    required |= {"scripts/" + name for name in PUBLIC_SCRIPTS}
    required |= {"macos/" + name for name in NATIVE_BUILD_FILES}
    required |= {"docs/" + name for name in PUBLIC_DOCS}
    required |= {"THIRD_PARTY/" + name for name in NOTICE_FILES}
    required |= {"tools/build-brand-icon.swift", "tools/export-tabler.swift"}
    required |= {"Assets/Brand/ChengWen.svg"}
    selected = {p.relative_to(ROOT).as_posix() for p in source_files()}
    missing = sorted(required - selected)
    if missing:
        raise ValueError("Incomplete public source: " + ", ".join(missing))
    license_text = (ROOT / "LICENSE").read_text()
    if not all(text in license_text for text in ("MIT License", "Copyright", "Permission is hereby granted")):
        raise ValueError("Project MIT copyright/license notice missing")
    dependencies = json.loads((ROOT / "THIRD_PARTY/dependencies.json").read_text())
    if len(dependencies) != 3 or not all(item.get("license") == "MIT" and item.get("version") for item in dependencies):
        raise ValueError("Third-party manifest must identify the reviewed MIT versions")
    for name in ("tabler-icons-LICENSE.txt", "TuneWeave-MIT.txt", "Listen1-MIT.txt"):
        notice = (ROOT / "THIRD_PARTY" / name).read_text()
        if "MIT License" not in notice or "Copyright" not in notice:
            raise ValueError("Missing third-party copyright/license: " + name)
    release_info()
    return selected


def source_mode(path):
    return 0o100755 if path.stat().st_mode & 0o111 else 0o100644


def update_source_digest(digest, relative, mode, content):
    # Include normalized archive permissions: losing a launcher's execute bit
    # changes the delivered source even when its text is identical.
    digest.update(relative.encode() + b"\0" + str(mode).encode() + b"\0")
    digest.update(len(content).to_bytes(8, "big") + content)


def source_digest():
    digest = hashlib.sha256()
    digest.update(b"ChengWen-source-v3\0")
    for path in source_files():
        update_source_digest(digest, path.relative_to(ROOT).as_posix(), source_mode(path), path.read_bytes())
    return digest.hexdigest()


def source_archive(destination):
    files = source_files()
    resolved = Path(destination).resolve()
    if resolved.is_relative_to(ROOT.resolve()):
        relative = resolved.relative_to(ROOT.resolve())
        if relative.parts[0] in {"Sources", "Tests"} or resolved in {path.resolve() for path in files}:
            raise ValueError("Source archive destination must stay outside public source inputs")
    digest = hashlib.sha256()
    digest.update(b"ChengWen-source-v3\0")
    with zipfile.ZipFile(destination, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in files:
            relative = path.relative_to(ROOT).as_posix()
            mode = source_mode(path)
            content = path.read_bytes()
            update_source_digest(digest, relative, mode, content)
            # Export stable timestamps and Unix execution bits. In particular,
            # Finder must still be able to launch the extracted .command file.
            entry = zipfile.ZipInfo("澄闻/" + relative, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = mode << 16
            archive.writestr(entry, content, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    return digest.hexdigest()


def prepare_tools():
    """Host-only tools; this environment is never an App copy input."""
    environment = CACHE / "package-tools"
    python = environment / "bin/python"
    if not python.exists():
        execute(["uv", "venv", "--python", "3.12.13", environment])
    execute(["uv", "pip", "install", "--python", python, "-r", ROOT / "macos/build-requirements.txt"])
    return python


def build_metadata():
    def output(*arguments):
        try:
            return subprocess.check_output(arguments, cwd=ROOT, stderr=subprocess.DEVNULL, text=True).strip()
        except (OSError, subprocess.CalledProcessError):
            return None
    git_root = output("git", "rev-parse", "--show-toplevel")
    own_repository = git_root is not None and Path(git_root).resolve() == ROOT.resolve()
    return {"swift": output("swift", "--version"), "xcode": output("xcodebuild", "-version"),
            "host_python": platform.python_version(), "host_macos": platform.mac_ver()[0],
            "source_commit": output("git", "rev-parse", "HEAD") if own_repository else None,
            "source_dirty": bool(output("git", "status", "--porcelain")) if own_repository else None}


@contextmanager
def owned_stage(output, prefix):
    stage = Path(tempfile.mkdtemp(prefix=prefix, dir=output))
    try:
        yield stage
    finally:
        if not (stage / ".preserve-mounted-stage").exists():
            shutil.rmtree(stage)


@contextmanager
def mounted_image(image, mount):
    """Detach this invocation's mount even if attach fails after mounting."""
    attached = False
    try:
        try:
            execute(["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount, image], stdout=subprocess.DEVNULL)
            attached = True
        except BaseException:
            attached = os.path.ismount(mount) or (mount / "澄闻.app").exists()
            raise
        yield mount
    finally:
        if attached:
            try:
                execute(["hdiutil", "detach", mount, "-quiet"])
            except BaseException:
                (mount.parent / ".preserve-mounted-stage").write_text("Inspect and eject the owned installer mount before cleanup.\n")
                CACHE.mkdir(parents=True, exist_ok=True)
                (CACHE / "packaging-blocked.json").write_text(json.dumps({"pid": os.getpid(), "mount": str(mount), "stage": str(mount.parent)}, indent=2) + "\n")
                raise RuntimeError("Installer could not be detached; preserved stage and blocked further packaging: " + str(mount.parent))


def build(architecture):
    with (CACHE / f"swift-{architecture}.log").open("w") as log:
        execute(["swift", "build", "--scratch-path", ROOT / f".build-native-{architecture}", "-c", "release", "--arch", architecture, "-Xswiftc", "-Osize"], stdout=log, stderr=subprocess.STDOUT)


def native_binary_directory(architecture):
    return Path(subprocess.check_output(["swift", "build", "--scratch-path", str(ROOT / f".build-native-{architecture}"), "-c", "release", "--arch", architecture, "--show-bin-path"], cwd=ROOT, text=True).strip())


def native_resource_bundle(directory):
    bundles = list(directory.glob("ChengWen_*.bundle"))
    if len(bundles) != 1 or not bundles[0].is_dir():
        raise RuntimeError("Native resource bundle missing or ambiguous")
    return bundles[0]


def verify_build_cache(architecture, expected_source, reuse):
    if source_digest() != expected_source:
        raise RuntimeError("Source changed during build; rebuild both installers")
    receipt = CACHE / f"swift-{architecture}-build.json"
    try:
        directory = native_binary_directory(architecture)
        bundle = native_resource_bundle(directory)
        files = [directory / "ChengWen", *sorted(path for path in bundle.rglob("*") if path.is_file())]
        environment = build_metadata()
        record = {
            "source_sha256": expected_source,
            "toolchain": {key: environment[key] for key in ("swift", "xcode", "host_macos")},
            "files": {path.relative_to(directory).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest() for path in files},
        }
        if not reuse:
            receipt.write_text(json.dumps(record, indent=2) + "\n")
            return
        if json.loads(receipt.read_text()) == record:
            return
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        if not reuse:
            raise
        raise RuntimeError(f"Cannot verify cached {architecture} build; rerun without --skip-build") from error
    raise RuntimeError(f"Cached {architecture} build differs from its source or artifacts; rerun without --skip-build")


def binary_uuids(path):
    output = subprocess.check_output(["/usr/bin/dwarfdump", "--uuid", str(path)], text=True)
    pairs = re.findall(r"UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)", output)
    if not pairs:
        raise RuntimeError(f"No Mach-O UUID found: {path.name}")
    return {architecture: uuid.upper() for uuid, architecture in pairs}


def archive_symbols(binary, bundle, architecture, version):
    """Archive matching symbols outside the cache before stripping a copy."""
    if not bundle.is_dir():
        raise RuntimeError("Release dSYM missing; refusing to strip executable")
    uuids = binary_uuids(binary)
    if set(uuids) != {architecture} or binary_uuids(bundle) != uuids:
        raise RuntimeError("Release executable and dSYM UUID/CPU do not match")
    archive_root = ROOT / "维护记录/澄闻" / f"{version}-symbols"
    archive_root.mkdir(parents=True, exist_ok=True)
    destination = archive_root / f"澄闻-{architecture}-{uuids[architecture]}.dSYM.zip"
    files = sorted(p for p in bundle.rglob("*") if p.is_file())
    expected = {"ChengWen.dSYM/" + p.relative_to(bundle).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    if destination.exists():
        with zipfile.ZipFile(destination) as archive:
            actual = {name: hashlib.sha256(archive.read(name)).hexdigest() for name in archive.namelist()}
        if actual != expected:
            raise RuntimeError("Existing symbol archive differs; refusing overwrite")
    else:
        no_existing(destination)
        with zipfile.ZipFile(destination, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for path in files:
                archive.write(path, "ChengWen.dSYM/" + path.relative_to(bundle).as_posix())
    return {"uuid": uuids[architecture], "archive": destination.relative_to(ROOT).as_posix(), "archive_sha256": hashlib.sha256(destination.read_bytes()).hexdigest()}


def assemble(application, architecture, version):
    validate_public_source()
    contents = application / "Contents"
    binaries, resources = contents / "MacOS", contents / "Resources"
    binaries.mkdir(parents=True)
    resources.mkdir()
    swift = native_binary_directory(architecture)
    binary = binaries / "ChengWen"
    symbols = archive_symbols(swift / "ChengWen", swift / "ChengWen.dSYM", architecture, version)
    shutil.copy2(swift / "ChengWen", binary)
    symbols["original_bytes"] = binary.stat().st_size
    execute(["/usr/bin/strip", "-S", "-x", binary])
    if binary_uuids(binary) != {architecture: symbols["uuid"]}:
        raise RuntimeError("Stripping changed executable UUID/CPU")
    symbols["stripped_bytes"] = binary.stat().st_size
    symbols["removed_bytes"] = symbols["original_bytes"] - symbols["stripped_bytes"]
    bundle = native_resource_bundle(swift)
    shutil.copytree(bundle, resources / bundle.name, symlinks=True)
    info = release_info()
    info.update(LSApplicationCategoryType="public.app-category.music", CFBundleSupportedPlatforms=["MacOSX"], LSArchitecturePriority=[architecture])
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    shutil.copy2(ROOT / "澄闻.app/Contents/Resources/AppIcon.icns", resources)
    shutil.copy2(ROOT / "LICENSE", resources / "LICENSE")
    notices = resources / "THIRD_PARTY"
    notices.mkdir()
    for name in NOTICE_FILES:
        shutil.copy2(ROOT / "THIRD_PARTY" / name, notices / name)
    source_hash = source_archive(resources / f"澄闻-{version}-source.zip")
    manifest = {"version": version, "build": info["CFBundleVersion"], "frontend": "SwiftUI+AppKit", "backend": "Swift", "pure_swift": True, "python_runtime": False, "source_sha256": source_hash, "built_utc": datetime.now(timezone.utc).isoformat(), "minimum_macos": info["LSMinimumSystemVersion"], "target_macos": "12.7.6", "architectures": [architecture], "signature": "ad-hoc", "notarized": False, "monterey_hardware_tested": False, "native_symbols": symbols, "build_environment": build_metadata()}
    (resources / "Release.json").write_text(json.dumps(manifest, indent=2) + "\n")
    execute(["codesign", "--force", "--deep", "--sign", "-", "--options=0", application])
    return verify(application, (architecture,)) | {"source_sha256": source_hash, "native_symbols": symbols}


def package(output, architecture, version, expected_source, python):
    final, checksum, report_path = installer_paths(output, version, architecture)
    no_existing(final, checksum, report_path)
    with owned_stage(output, f".chengwen-{architecture}-") as stage:
        application = stage / "澄闻.app"
        report = assemble(application, architecture, version)
        if report["source_sha256"] != expected_source:
            raise RuntimeError("Source changed during build; rebuild both installers")
        report["native_smoke"] = smoke(application, architecture)
        execute(["swift", ROOT / "macos/create-dmg-background.swift", stage / "background.png"])
        image = stage / final.name
        cpu = "Apple Silicon" if architecture == "arm64" else "Intel"
        execute([python.parent / "dmgbuild", "-s", ROOT / "macos/dmg-settings.py", "-D", f"app={application}", "-D", f"background={stage / 'background.png'}", f"澄闻 {version} {cpu}", image])
        execute(["hdiutil", "verify", image])
        mount = stage / "mounted"
        mount.mkdir()
        with mounted_image(image, mount):
            execute([python, ROOT / "macos/verify-dmg-layout.py", mount, "澄闻.app"])
            verify(mount / "澄闻.app", (architecture,))
            installed = stage / "installed/澄闻.app"
            installed.parent.mkdir()
            execute(["ditto", mount / "澄闻.app", installed])
            report["installed_copy_smoke"] = smoke(installed, architecture)
        report.update(finder_layout="960x600 blue background; icons 260,298 / 700,298; Applications link verified", dmg_format="ULMO", dmg_bytes=image.stat().st_size, app_bytes=sum(p.stat().st_size for p in application.rglob("*") if p.is_file() and not p.is_symlink()))
        digest = hashlib.sha256(image.read_bytes()).hexdigest()
        report["dmg_sha256"] = digest
        if source_digest() != expected_source:
            raise RuntimeError("Source changed while packaging")
        staged_checksum, staged_report = stage / checksum.name, stage / report_path.name
        staged_checksum.write_text(f"{digest}  {final.name}\n")
        staged_report.write_text(json.dumps(report, indent=2) + "\n")
        no_existing(final, checksum, report_path)
        publish_artifacts(((image, final), (staged_checksum, checksum), (staged_report, report_path)))
    print(f"Created {final} ({report['dmg_bytes'] / 1048576:.2f} MiB)", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--architecture", choices=("all", "arm64", "x86_64"), default="all")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dist/native")
    parser.add_argument("--skip-build", action="store_true", help="Reuse an unchanged build recorded by this packaging script")
    parser.add_argument("--preflight", action="store_true", help="Check source, tools and output collisions without building or downloading tools")
    args = parser.parse_args()
    output = args.output_dir.expanduser().absolute()
    if CACHE.resolve().parent != ROOT.resolve():
        raise ValueError("Build cache must stay inside project")
    validate_public_source()
    version = release_info()["CFBundleShortVersionString"]
    architectures = ("arm64", "x86_64") if args.architecture == "all" else (args.architecture,)
    for architecture in architectures:
        no_existing(*installer_paths(output, version, architecture))
    missing_tools = [tool for tool in ("swift", "xcrun", "uv", "codesign", "hdiutil", "ditto", "ffmpeg", "ffprobe") if shutil.which(tool) is None]
    if missing_tools:
        raise RuntimeError("Missing host tools: " + ", ".join(missing_tools) + "; see docs/DEVELOPMENT.md")
    if args.preflight:
        print(json.dumps({"version": version, "architectures": architectures, "source_sha256": source_digest(), "build_environment": build_metadata(), "preflight": "passed"}, indent=2))
        return
    output.mkdir(parents=True, exist_ok=True)
    with PackagingLock(CACHE), termination_handlers():
        expected_source = source_digest()
        python = prepare_tools()
        for architecture in architectures:
            if not args.skip_build:
                print(f"Building pure Swift application: {architecture}", flush=True)
                build(architecture)
            verify_build_cache(architecture, expected_source, reuse=args.skip_build)
            package(output, architecture, version, expected_source, python)


if __name__ == "__main__":
    main()
