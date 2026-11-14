"""Commands shared by source, Nuitka, and PyInstaller runs."""

import sys
from pathlib import Path


def tool_command(mode, arguments=()):
    """Return a program and argument list, without invoking a shell."""
    packaged = "__compiled__" in globals() or getattr(sys, "frozen", False)
    prefix = [] if packaged else [
        "-u", str(Path(__file__).resolve().with_name("drift_correct.py"))
    ]
    return sys.executable, [*prefix, "--tool", mode, *arguments]
