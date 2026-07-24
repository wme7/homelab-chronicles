"""Ensure native parallel-ssh (ssh2-python) can find libssh2 on macOS."""

from __future__ import annotations

import os
import sys
from pathlib import Path

_MARKER = "_CLUSTER_LIBSSH2_READY"

_LIB_CANDIDATES = (
    Path("/opt/homebrew/opt/libssh2/lib"),
    Path("/usr/local/opt/libssh2/lib"),
)


def ensure_libssh2() -> None:
    """Re-exec with DYLD_FALLBACK_LIBRARY_PATH if ssh2 cannot load libssh2."""
    if os.environ.get(_MARKER):
        return

    try:
        import ssh2.error_codes  # noqa: F401
        return
    except ImportError:
        pass

    libs = [str(path) for path in _LIB_CANDIDATES if path.is_dir()]
    if not libs:
        return

    env = os.environ.copy()
    env[_MARKER] = "1"
    previous = env.get("DYLD_FALLBACK_LIBRARY_PATH", "")
    parts = libs + ([previous] if previous else [])
    env["DYLD_FALLBACK_LIBRARY_PATH"] = ":".join(parts)
    os.execve(sys.executable, [sys.executable, *sys.argv], env)
