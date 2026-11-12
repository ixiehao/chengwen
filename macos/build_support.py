"""Host-only packaging safeguards. Nothing here runs inside the App."""
from __future__ import annotations

from contextlib import contextmanager
import ctypes
import errno
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid


def terminate_process_group(process):
    """Reap the child and stop remaining descendants in its owned session.

    Waiting only for the direct child is insufficient: it may exit on TERM
    while a descendant ignores the signal and continues writing build files.
    """
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        process.wait()
        return
    deadline = time.monotonic() + 5
    while True:
        process.poll()  # Reap the direct child so it cannot keep the group alive.
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            break
        except PermissionError:
            # A group probe can race an exiting/reaped child. Do not mistake
            # a denied probe for proof of exit; keep the bounded cleanup wait
            # and still attempt KILL if the group never disappears.
            pass
        if time.monotonic() >= deadline:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            break
        time.sleep(0.02)
    process.wait()


def run_checked(arguments, **options):
    """Terminate the whole child group when the owning build is interrupted."""
    timeout = options.pop("timeout", None)
    if options.pop("capture_output", False):
        options.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    command = [str(item) for item in arguments]
    process = subprocess.Popen(command, start_new_session=True, **options)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException:
        terminate_process_group(process)
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None:
                stream.close()
        raise
    if process.returncode:
        raise subprocess.CalledProcessError(process.returncode, command, output=stdout, stderr=stderr)
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


@contextmanager
def termination_handlers():
    def terminate(number, _frame):
        raise SystemExit(128 + number)
    original = {number: signal.getsignal(number) for number in (signal.SIGINT, signal.SIGTERM)}
    try:
        for number in original:
            signal.signal(number, terminate)
        yield
    finally:
        for number, handler in original.items():
            signal.signal(number, handler)


class PackagingLock:
    """An advisory lock owns the inode; mere existence is not a stale lock.

    Keep the file instead of unlinking it: unlinking a flock'ed inode permits a
    third process to lock a new inode while another waiter owns the old one.
    """
    def __init__(self, cache):
        self.cache = Path(cache)
        self.path = self.cache / "packaging.lock"
        self.stream = None

    def __enter__(self):
        self.cache.mkdir(parents=True, exist_ok=True)
        self.stream = self.path.open("a+")
        try:
            fcntl.flock(self.stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.stream.seek(0)
            owner = self.stream.read().strip()
            self.stream.close(); self.stream = None
            raise RuntimeError("Another packaging run owns the build cache: " + owner)
        try:
            blocked = self.cache / "packaging-blocked.json"
            if blocked.exists():
                raise RuntimeError("An installer mount needs manual cleanup; inspect " + str(blocked))
            self.stream.seek(0); self.stream.truncate()
            json.dump({"pid": os.getpid(), "token": uuid.uuid4().hex}, self.stream)
            self.stream.flush(); os.fsync(self.stream.fileno())
        except BaseException:
            self.__exit__(None, None, None)
            raise
        return self

    def __exit__(self, *_):
        if self.stream is not None:
            self.stream.seek(0); self.stream.truncate(); self.stream.flush()
            fcntl.flock(self.stream.fileno(), fcntl.LOCK_UN)
            self.stream.close(); self.stream = None


def exclusive_rename(source, destination):
    """Publish without overwrite; unsupported volumes must fail explicitly."""
    if sys.platform != "darwin":
        raise RuntimeError("Native installer publication requires macOS renamex_np")
    library = ctypes.CDLL(None, use_errno=True)
    rename = library.renamex_np
    rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 0x00000004) != 0:  # RENAME_EXCL
        number = ctypes.get_errno()
        if number == errno.EEXIST:
            raise FileExistsError(number, os.strerror(number), str(destination))
        if number in (errno.ENOTSUP, errno.EOPNOTSUPP, errno.ENOSYS):
            raise OSError(number, "Installer output requires exclusive rename support; choose a local APFS output directory", str(destination))
        raise OSError(number, os.strerror(number), str(destination))


def publish_artifacts(pairs):
    """Rollback only files whose inode is still owned by this invocation."""
    published = []
    try:
        for source, destination in pairs:
            identity = (source.stat().st_dev, source.stat().st_ino)
            exclusive_rename(source, destination)
            published.append((source, destination, identity))
    except BaseException:
        for source, destination, identity in reversed(published):
            if destination.exists() and (destination.stat().st_dev, destination.stat().st_ino) == identity:
                exclusive_rename(destination, source)
        raise
