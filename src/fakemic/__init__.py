"""fakemic — fake virtual microphone manager (silent / white-noise) for PipeWire.

This package is a thin launcher around the real implementation in
``fakemic.sh``. The bash script is shipped as package data and executed via
``bash`` so it runs in the user's session environment (HOME, XDG_RUNTIME_DIR,
PATH to pactl/sox/systemctl). This keeps the tool pipx/uv/pip-installable while
leaving the logic in a single editable bash script.
"""

from __future__ import annotations

import os
import sys
from importlib.resources import files


def _script_path() -> str:
    """Return the on-disk path to the bundled fakemic.sh."""
    return str(files(__package__).joinpath("fakemic.sh"))


def main() -> "int":
    """Entry point (`fakemic` console script). Replaces this process with bash."""
    path = _script_path()
    # os.execvp replaces the current process; bash inherits the caller's
    # environment (HOME, XDG_RUNTIME_DIR, DBUS_SESSION_BUS_ADDRESS, PATH, ...).
    os.execvp("bash", ["bash", path, *sys.argv[1:]])


if __name__ == "__main__":
    raise SystemExit(main())