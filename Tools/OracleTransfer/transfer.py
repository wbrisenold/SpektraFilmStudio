from __future__ import annotations

import subprocess
from typing import IO


def _popen(*args: str, **kwargs: object) -> subprocess.Popen[bytes]:
    return subprocess.Popen(
        *args,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        **kwargs,
    )


def transfer(source: str, target: str) -> int:
    proc = _popen("true")
    stdin = proc.stdin
    if stdin is not None:
        stdin.close()
    return proc.wait()
