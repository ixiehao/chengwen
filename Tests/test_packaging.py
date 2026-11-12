import json
from pathlib import Path
import struct
import zipfile

import pytest

from macos.package_dmg import no_existing, source_files
from macos.native_package_smoke import validate_report
from macos.verify_app import audit_native_contents


def test_packaging_refuses_existing_output_and_broken_symlink(tmp_path):
    existing = tmp_path / "ChengWen.dmg"
    existing.write_bytes(b"previous installer")
    with pytest.raises(FileExistsError):
        no_existing(existing)
    assert existing.read_bytes() == b"previous installer"
    missing = tmp_path / "ChengWen.dmg.sha256"
    missing.symlink_to(tmp_path / "not-created")
    with pytest.raises(FileExistsError):
        no_existing(missing)
    assert missing.is_symlink()


def test_native_source_archive_excludes_legacy_engines_and_builds(tmp_path, monkeypatch):
    from macos import package_dmg
    for name in ("Package.swift", "Sources/ChengWen/App.swift", "chengwen/private.py", "macos/Engine.spec", ".venv/private.py", ".build-native/generated.swift"):
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("synthetic source")
    monkeypatch.setattr(package_dmg, "ROOT", tmp_path)
    recorded = package_dmg.source_archive(tmp_path / "source.zip")
    with zipfile.ZipFile(tmp_path / "source.zip") as archive:
        assert archive.namelist() == ["澄闻/Package.swift", "澄闻/Sources/ChengWen/App.swift"]
    assert recorded == package_dmg.source_digest()


def test_source_archive_excludes_builds_and_virtual_environments():
    for path in source_files():
        assert not {".venv", ".build-release", "__pycache__", "dist", "build"}.intersection(path.parts)
        assert not path.relative_to(Path(__file__).resolve().parent.parent).as_posix().startswith("chengwen/")


def test_source_changed_during_build_is_detected(tmp_path, monkeypatch):
    from macos import package_dmg
    source = tmp_path / "app.swift"
    source.write_text("original release source\n")
    monkeypatch.setattr(package_dmg, "ROOT", tmp_path)
    monkeypatch.setattr(package_dmg, "source_files", lambda: [source])
    recorded = package_dmg.source_archive(tmp_path / "source.zip")
    assert recorded == package_dmg.source_digest()
    source.write_text("changed while packaging\n")
    assert recorded != package_dmg.source_digest()


@pytest.mark.parametrize("cpu,architecture", [(0x1000007, "x86_64"), (0x100000c, "arm64")])
def test_macho_cpu_and_minimum_os_are_read_from_load_commands(cpu, architecture):
    from macos.verify_app import slices
    header = struct.pack("<8I", 0xfeedfacf, cpu, 0, 2, 1, 24, 0, 0)
    command = struct.pack("<6I", 0x32, 24, 1, 12 << 16, 27 << 16, 0)
    assert list(slices(header + command)) == [{"architecture": architecture, "minimum": (12, 0, 0)}]


def valid_smoke():
    return {"passed": True, "pure_swift": True, "native_ui": True, "native_webkit": True, "selection_and_fragments": True, "frontend": "SwiftUI+AppKit", "backend": {"passed": True, "implementation": "Swift", "no_python": True}}


@pytest.mark.parametrize("change", [{"pure_swift": False}, {"native_webkit": False}, {"backend": {"passed": True, "python": "3.12"}}, {"backend": {"passed": False}}])
def test_smoke_rejects_old_engine_or_failed_native_checks(change):
    with pytest.raises(RuntimeError):
        validate_report(valid_smoke() | change)


def test_smoke_accepts_fully_native_check():
    assert validate_report(valid_smoke())["passed"]


def minimal_native_app(tmp_path):
    app = tmp_path / "澄闻.app"
    resources = app / "Contents/Resources"
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/MacOS/ChengWen").write_bytes(b"synthetic executable")
    bundle = resources / "ChengWen_ChengWen.bundle/Resources/Tabler"
    bundle.mkdir(parents=True)
    (bundle / "music.png").write_bytes(b"synthetic icon")
    (bundle / "LICENSE").write_text("MIT License")
    (resources / "AppIcon.icns").write_bytes(b"synthetic icon")
    license_text = "MIT License\nCopyright (c) 2026 Synthetic contributors\nPermission is hereby granted"
    (resources / "LICENSE").write_text(license_text)
    (bundle.parent / "Version.json").write_text(json.dumps({"version": "0.6.0", "build": "600"}))
    notices = resources / "THIRD_PARTY"
    notices.mkdir()
    for name in ("README.md", "tabler-icons-LICENSE.txt", "TuneWeave-MIT.txt", "Listen1-MIT.txt"):
        (notices / name).write_text("MIT License")
    (notices / "dependencies.json").write_text(json.dumps([{"name": "Tabler", "license": "MIT"}, {"name": "TuneWeave", "license": "MIT"}, {"name": "Listen1", "license": "MIT"}]))
    (resources / "Release.json").write_text(json.dumps({"version": "0.6.0", "build": "600", "pure_swift": True, "python_runtime": False, "backend": "Swift"}))
    with zipfile.ZipFile(resources / "澄闻-0.6.0-source.zip", "w") as archive:
        archive.writestr("澄闻/Package.swift", "synthetic package")
        archive.writestr("澄闻/LICENSE", license_text)
        for name in ("CONTRIBUTING.md", "PRIVACY.md", "SECURITY.md", "CHANGELOG.md", "dev-requirements.txt", ".github/workflows/ci.yml", "Tests/test_packaging.py", "scripts/validate.py", "scripts/export_source.py", "scripts/verify_public_source.py"):
            archive.writestr("澄闻/" + name, "Synthetic public material")
        archive.writestr("澄闻/Sources/ChengWen/App.swift", "synthetic native source")
    return app


def test_native_bundle_audit_accepts_minimal_native_resources(tmp_path):
    assert audit_native_contents(minimal_native_app(tmp_path), "0.6.0")["python_runtime"] is False


@pytest.mark.parametrize("extra", ["Engine/ChengWenEngine", "python3.12/libpython.dylib", "leftover.so", "Debug.dSYM/Info.plist"])
def test_native_bundle_audit_rejects_accidental_runtime_or_debug_artifacts(tmp_path, extra):
    app = minimal_native_app(tmp_path)
    path = app / "Contents/Resources" / extra
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"must not ship")
    with pytest.raises(AssertionError):
        audit_native_contents(app, "0.6.0")


def test_symbol_uuid_mismatch_prevents_archival_and_stripping(tmp_path, monkeypatch):
    from macos import package_dmg
    binary, bundle = tmp_path / "ChengWen", tmp_path / "ChengWen.dSYM"
    binary.write_bytes(b"synthetic binary")
    bundle.mkdir()
    monkeypatch.setattr(package_dmg, "ROOT", tmp_path)
    monkeypatch.setattr(package_dmg, "binary_uuids", lambda path: {"arm64": "A" if path == binary else "B"})
    with pytest.raises(RuntimeError, match="UUID/CPU"):
        package_dmg.archive_symbols(binary, bundle, "arm64", "0.6.0")
    assert not (tmp_path / "维护记录").exists()
    assert binary.read_bytes() == b"synthetic binary"


def test_project_license_and_resource_version_are_required(tmp_path):
    app = minimal_native_app(tmp_path)
    license_file = app / "Contents/Resources/LICENSE"
    original = license_file.read_text()
    license_file.write_text("No redistribution license")
    with pytest.raises(AssertionError, match="Project license"):
        audit_native_contents(app, "0.6.0")
    license_file.write_text(original)
    version = app / "Contents/Resources/ChengWen_ChengWen.bundle/Resources/Version.json"
    version.write_text(json.dumps({"version": "0.6.0", "build": "wrong"}))
    with pytest.raises(AssertionError, match="version mismatch"):
        audit_native_contents(app, "0.6.0")


def test_current_public_allowlist_is_complete_and_rejects_workspace_history():
    from macos.package_dmg import validate_public_source
    names = validate_public_source()
    assert "LICENSE" in names and "Tests/test_packaging.py" in names
    assert "tools/build-brand-icon.swift" in names
    assert ".github/workflows/ci.yml" in names
    assert not any(name.startswith(("维护记录/", "docs/youget-probe/", "tools/probe_youget")) or "YOUGET_PROBE" in name for name in names)


def test_release_resource_and_plist_version_must_match(tmp_path, monkeypatch):
    import plistlib
    from macos import package_dmg
    plist = tmp_path / "澄闻.app/Contents/Info.plist"; plist.parent.mkdir(parents=True)
    resource = tmp_path / "Sources/ChengWen/Resources/Version.json"; resource.parent.mkdir(parents=True)
    plist.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "100"}))
    resource.write_text(json.dumps({"version": "1.0.0", "build": "99"}))
    monkeypatch.setattr(package_dmg, "ROOT", tmp_path)
    with pytest.raises(ValueError, match="do not match"):
        package_dmg.release_info()


def test_missing_public_license_fails_before_building(tmp_path, monkeypatch):
    from macos import package_dmg
    monkeypatch.setattr(package_dmg, "ROOT", tmp_path)
    with pytest.raises(ValueError, match="LICENSE"):
        package_dmg.validate_public_source()


def test_public_export_manifest_describes_actual_archived_bytes(tmp_path):
    import hashlib
    import os
    import subprocess
    import sys
    project = Path(__file__).resolve().parent.parent
    archive = tmp_path / "public.zip"
    subprocess.run([sys.executable, project / "scripts/export_source.py", archive], check=True, capture_output=True, text=True, env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
    manifest = json.loads(archive.with_name(archive.name + ".manifest.json").read_text())
    assert manifest["archive_sha256"] == hashlib.sha256(archive.read_bytes()).hexdigest()
    with zipfile.ZipFile(archive) as source:
        assert "澄闻/LICENSE" in source.namelist()
        assert "澄闻/docs/screenshot.png" in source.namelist()
        for record in manifest["files"]:
            assert hashlib.sha256(source.read("澄闻/" + record["path"])).hexdigest() == record["sha256"]


def test_source_symlink_cannot_pull_external_private_file(tmp_path, monkeypatch):
    from macos import package_dmg
    secret = tmp_path / "outside.txt"; secret.write_text("synthetic private data")
    root = tmp_path / "project"; (root / "Sources").mkdir(parents=True)
    (root / "Sources/linked.txt").symlink_to(secret)
    monkeypatch.setattr(package_dmg, "ROOT", root)
    with pytest.raises(ValueError, match="symlinks or external"):
        package_dmg.source_files()


def test_archive_uses_exclusive_creation(tmp_path):
    from macos.package_dmg import source_archive
    path = tmp_path / "source.zip"; path.write_bytes(b"old artifact")
    with pytest.raises(FileExistsError):
        source_archive(path)
    assert path.read_bytes() == b"old artifact"


def test_native_publication_does_not_replace_existing_file(tmp_path):
    from macos.build_support import exclusive_rename
    first, destination = tmp_path / "new", tmp_path / "existing"
    first.write_text("new"); destination.write_text("old")
    with pytest.raises(FileExistsError):
        exclusive_rename(first, destination)
    assert first.read_text() == "new" and destination.read_text() == "old"
    destination.unlink(); exclusive_rename(first, destination)
    assert destination.read_text() == "new" and not first.exists()


def test_partial_publication_rolls_back_only_owned_files(tmp_path, monkeypatch):
    from macos import build_support
    sources = [tmp_path / (str(index) + ".stage") for index in range(3)]
    targets = [tmp_path / (str(index) + ".final") for index in range(3)]
    for index, path in enumerate(sources):
        path.write_text(str(index))
    targets[1].write_text("previous installer")
    with pytest.raises(FileExistsError):
        build_support.publish_artifacts(zip(sources, targets))
    assert all(path.exists() for path in sources)
    assert not targets[0].exists() and targets[1].read_text() == "previous installer"


def test_attach_failure_after_mounting_still_detaches_owned_mount(tmp_path, monkeypatch):
    from macos import package_dmg
    mount = tmp_path / "stage/mount"; mount.mkdir(parents=True)
    calls = []
    def fake_execute(arguments, **_):
        calls.append(arguments[1])
        if arguments[1] == "attach":
            (mount / "澄闻.app").mkdir()
            raise RuntimeError("attach reported failure after mounting")
        (mount / "澄闻.app").rmdir()
    monkeypatch.setattr(package_dmg, "execute", fake_execute)
    with pytest.raises(RuntimeError, match="attach reported"):
        with package_dmg.mounted_image(tmp_path / "synthetic.dmg", mount):
            pytest.fail("A failed attachment cannot continue verification")
    assert calls == ["attach", "detach"]


def test_failed_detach_preserves_stage_and_blocks_next_build(tmp_path, monkeypatch):
    from macos import package_dmg
    from macos.build_support import PackagingLock
    cache = tmp_path / "cache"
    monkeypatch.setattr(package_dmg, "CACHE", cache)
    def fake_execute(arguments, **_):
        if arguments[1] == "detach":
            raise RuntimeError("Synthetic busy mount")
    monkeypatch.setattr(package_dmg, "execute", fake_execute)
    with pytest.raises(RuntimeError, match="preserved stage"):
        with package_dmg.owned_stage(tmp_path, "owned-") as stage:
            mount = stage / "mount"; mount.mkdir()
            with package_dmg.mounted_image(tmp_path / "synthetic.dmg", mount):
                pass
    assert stage.is_dir() and (cache / "packaging-blocked.json").is_file()
    with pytest.raises(RuntimeError, match="manual cleanup"):
        with PackagingLock(cache):
            pytest.fail("A known mounted image must block reuse")


def test_competing_process_cannot_take_or_remove_build_lock(tmp_path):
    import os
    import subprocess
    import sys
    from macos.build_support import PackagingLock
    cache = tmp_path / "cache"
    code = "from macos.build_support import PackagingLock\nwith PackagingLock(" + repr(str(cache)) + "): pass\n"
    with PackagingLock(cache) as owner:
        recorded = owner.path.read_text()
        result = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
        assert result.returncode != 0 and "Another packaging run" in result.stderr
        assert owner.path.read_text() == recorded
    assert owner.path.read_text() == ""
    with PackagingLock(cache):
        pass


def test_sigterm_reaps_child_and_cleans_owned_stage_and_lock(tmp_path):
    import os
    import signal
    import subprocess
    import sys
    import time
    cache = tmp_path / "cache"; stages = tmp_path / "stages"; stages.mkdir()
    child_marker = tmp_path / "child-pid"
    child_code = "import os,time;from pathlib import Path;Path(" + repr(str(child_marker)) + ").write_text(str(os.getpid()));time.sleep(30)"
    code = "\n".join([
        "from macos.build_support import PackagingLock,termination_handlers,run_checked",
        "from macos.package_dmg import owned_stage",
        "from pathlib import Path",
        "import sys",
        "with PackagingLock(" + repr(str(cache)) + "), termination_handlers():",
        "    with owned_stage(Path(" + repr(str(stages)) + "), 'owned-'):",
        "        run_checked([sys.executable, '-c', " + repr(child_code) + "])",
    ])
    process = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
    try:
        deadline = time.monotonic() + 5
        while not child_marker.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert child_marker.exists(), "Synthetic child did not start"
        child_pid = int(child_marker.read_text())
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=10)
        assert process.returncode == 143, (stdout, stderr)
        assert list(stages.iterdir()) == []
        assert (cache / "packaging.lock").read_text() == ""
        with pytest.raises(ProcessLookupError):
            os.kill(child_pid, 0)
    finally:
        if process.poll() is None:
            process.kill(); process.wait()


def test_git_public_gate_rejects_force_added_private_material(tmp_path):
    import subprocess
    from scripts.verify_public_source import verify_tracked_files
    # This is an owned synthetic repository, never the developer's checkout.
    subprocess.run(["git", "-c", "init.defaultBranch=main", "init", str(tmp_path)], check=True, capture_output=True)
    (tmp_path / "public.txt").write_text("synthetic public source")
    subprocess.run(["git", "add", "public.txt"], cwd=tmp_path, check=True)
    assert verify_tracked_files({"public.txt"}, tmp_path)["git_tracking_check"] == "passed"
    private = tmp_path / "维护记录/private.txt"; private.parent.mkdir(); private.write_text("synthetic private marker")
    subprocess.run(["git", "add", "-f", "维护记录/private.txt"], cwd=tmp_path, check=True)
    with pytest.raises(ValueError, match="维护记录/private.txt") as failure:
        verify_tracked_files({"public.txt"}, tmp_path)
    assert "synthetic private marker" not in str(failure.value)


def test_git_public_gate_explicitly_marks_non_git_source(tmp_path):
    from scripts.verify_public_source import verify_tracked_files
    assert verify_tracked_files(set(), tmp_path)["git_tracking_check"].startswith("skipped:")


def test_source_archive_preserves_launcher_execute_bits_and_stable_bytes(tmp_path, monkeypatch):
    from macos import package_dmg
    launcher = tmp_path / "launch.command"
    launcher.write_text("#!/bin/zsh\nexit 0\n")
    launcher.chmod(0o755)
    monkeypatch.setattr(package_dmg, "ROOT", tmp_path)
    monkeypatch.setattr(package_dmg, "source_files", lambda: [launcher])
    first, second = tmp_path / "first.zip", tmp_path / "second.zip"
    assert package_dmg.source_archive(first) == package_dmg.source_digest()
    package_dmg.source_archive(second)
    assert first.read_bytes() == second.read_bytes()
    with zipfile.ZipFile(first) as archive:
        entry = archive.getinfo("澄闻/launch.command")
        assert (entry.external_attr >> 16) & 0o111 == 0o111
        assert archive.read(entry).startswith(b"#!/bin/zsh")


def test_native_audit_accepts_macos_contents_resource_bundle(tmp_path):
    app = minimal_native_app(tmp_path)
    bundle = app / "Contents/Resources/ChengWen_ChengWen.bundle"
    nested = bundle / "Contents/Resources"
    nested.mkdir(parents=True)
    (bundle / "Resources").rename(nested / "Resources")
    assert audit_native_contents(app, "0.6.0")["pure_swift"]


def test_native_audit_rejects_ambiguous_version_resource_layout(tmp_path):
    app = minimal_native_app(tmp_path)
    bundle = app / "Contents/Resources/ChengWen_ChengWen.bundle"
    duplicate = bundle / "Contents/Resources/Resources/Version.json"
    duplicate.parent.mkdir(parents=True)
    duplicate.write_text((bundle / "Resources/Version.json").read_text())
    with pytest.raises(AssertionError, match="ambiguous"):
        audit_native_contents(app, "0.6.0")


def test_source_digest_detects_execution_permission_changes(tmp_path, monkeypatch):
    from macos import package_dmg
    launcher = tmp_path / "launch.command"
    launcher.write_text("#!/bin/zsh\nexit 0\n")
    launcher.chmod(0o644)
    monkeypatch.setattr(package_dmg, "ROOT", tmp_path)
    monkeypatch.setattr(package_dmg, "source_files", lambda: [launcher])
    original = package_dmg.source_digest()
    launcher.chmod(0o755)
    assert package_dmg.source_digest() != original
    assert package_dmg.source_archive(tmp_path / "source.zip") == package_dmg.source_digest()


def test_source_archive_cannot_include_itself(tmp_path, monkeypatch):
    from macos import package_dmg
    (tmp_path / "Sources").mkdir()
    (tmp_path / "Sources/App.swift").write_text("synthetic source")
    monkeypatch.setattr(package_dmg, "ROOT", tmp_path)
    output = tmp_path / "Sources/source.zip"
    with pytest.raises(ValueError, match="outside public source"):
        package_dmg.source_archive(output)
    assert not output.exists()


def test_source_export_failure_leaves_no_partial_archive_or_sidecars(tmp_path, monkeypatch):
    from scripts import export_source
    from macos import build_support
    output = tmp_path / "public.zip"
    competing = output.with_name(output.name + ".sha256")
    def collide(pairs):
        competing.write_bytes(b"another export's checksum")
        build_support.publish_artifacts(pairs)
    monkeypatch.setattr(export_source, "publish_artifacts", collide)
    with pytest.raises(FileExistsError):
        export_source.export_source(output)
    assert not output.exists()
    assert not output.with_name(output.name + ".manifest.json").exists()
    assert competing.read_bytes() == b"another export's checksum"
    assert set(tmp_path.iterdir()) == {competing}


def test_sigterm_also_stops_descendant_that_ignores_term(tmp_path):
    import os
    import signal
    import subprocess
    import sys
    import time
    marker = tmp_path / "descendant-pid"
    descendant = "import os,signal,time;from pathlib import Path;signal.signal(signal.SIGTERM,signal.SIG_IGN);Path(" + repr(str(marker)) + ").write_text(str(os.getpid()));time.sleep(60)"
    child = "import subprocess,sys,time;subprocess.Popen([sys.executable,'-c'," + repr(descendant) + "]);time.sleep(60)"
    driver = "\n".join([
        "import subprocess,sys",
        "from macos.build_support import termination_handlers,run_checked",
        "with termination_handlers():",
        "    run_checked([sys.executable,'-c'," + repr(child) + "],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)",
    ])
    process = subprocess.Popen([sys.executable, "-c", driver], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
    descendant_pid = None
    try:
        deadline = time.monotonic() + 5
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert marker.exists(), "Synthetic descendant did not start"
        descendant_pid = int(marker.read_text())
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=12)
        assert process.returncode == 143, (stdout, stderr)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                os.kill(descendant_pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.02)
        else:
            pytest.fail("A TERM-resistant build descendant survived cancellation")
    finally:
        if process.poll() is None:
            process.kill(); process.wait()
        if descendant_pid is not None:
            try:
                os.kill(descendant_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


def test_cleanup_retries_denied_group_probe_instead_of_abandoning_cleanup(monkeypatch):
    import signal
    from macos import build_support
    calls = []
    class SyntheticProcess:
        pid = 12345
        def poll(self):
            return 0
        def wait(self):
            calls.append("reaped")
            return 0
    def signal_group(pid, number):
        calls.append(number)
        if number == 0:
            if calls.count(0) == 1:
                raise PermissionError("Synthetic transient exit race")
            raise ProcessLookupError()
    monkeypatch.setattr(build_support.os, "killpg", signal_group)
    monkeypatch.setattr(build_support.time, "sleep", lambda _: None)
    build_support.terminate_process_group(SyntheticProcess())
    assert calls == [signal.SIGTERM, 0, 0, "reaped"]
