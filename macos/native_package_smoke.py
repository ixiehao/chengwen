"""Run the actual native App's isolated GUI and local media checks."""
import json
import os
from pathlib import Path
import subprocess
try:
    from .build_support import run_checked
except ImportError:
    from build_support import run_checked


def validate_report(report):
    if not isinstance(report, dict):
        raise RuntimeError("Native smoke did not return a JSON object")
    required = ("passed", "pure_swift", "native_ui", "native_webkit", "selection_and_fragments")
    if not all(report.get(key) is True for key in required):
        raise RuntimeError("Native application check failed: " + json.dumps(report, ensure_ascii=False))
    if report.get("frontend") != "SwiftUI+AppKit":
        raise RuntimeError("Installer does not use the native frontend")
    backend = report.get("backend", {})
    if not isinstance(backend, dict) or backend.get("passed") is not True or backend.get("implementation") != "Swift" or backend.get("no_python") is not True or backend.get("python"):
        raise RuntimeError("Native music engine check failed")
    return report


def smoke(application, architecture):
    application = Path(application)
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("PYTHON", "QT_", "DYLD_", "_PYI", "CHENGWEN_"))}
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    try:
        result = run_checked(["/usr/bin/arch", "-" + architecture,
                              str(application / "Contents/MacOS/ChengWen"), "--native-smoke", "--hidden-preview"],
                             cwd=application.parent, env=environment, capture_output=True, text=True, timeout=100)
    except subprocess.CalledProcessError as failure:
        raise RuntimeError(f"Native app check failed: {(failure.stdout or '')[-4000:]}\n{(failure.stderr or '')[-1500:]}") from failure
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    if not lines:
        raise RuntimeError("Native app check returned no result")
    return validate_report(json.loads(lines[-1]))
