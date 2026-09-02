"""Parser for the merged WindowsUpdate.log produced by Get-WindowsUpdateLog.

Line format:
    2026/06/15 08:17:34.7361236 4968  6728  Shared   <message>
    <date>     <time>          pid   tid   comp     message

The log is huge (mostly informational), so this parser is *selective*: it emits
only warnings/errors/failures (the servicing problems), with the HRESULT pulled
out as the event code. Timestamps are the converting machine's local time; the
ETL loader converts them to UTC using that machine's offset.
"""

from __future__ import annotations

import re
from typing import Iterator

_LINE = re.compile(
    r"^(?P<y>\d{4})/(?P<mo>\d{2})/(?P<d>\d{2})\s+"
    r"(?P<h>\d{2}):(?P<mi>\d{2}):(?P<s>\d{2})\.(?P<frac>\d+)\s+"
    r"\d+\s+\d+\s+(?P<comp>\S+)\s+(?P<msg>.*)$"
)
# WU logs write HRESULTs as 0x8XXXXXXX or bracketed [8XXXXXXX]; capture both.
_HRESULT = re.compile(r"(?:0x|\[)(8[0-9A-Fa-f]{7})\b")
_FAIL = re.compile(r"\b(fail|failed|failure|fatal|error|cannot|denied)\b", re.I)
_WARN = re.compile(r"\bwarn", re.I)


def _ts(m) -> str:
    return (f"{m['y']}-{m['mo']}-{m['d']}T{m['h']}:{m['mi']}:{m['s']}."
            f"{(m['frac'] + '000000')[:6]}")


def parse_wulog(text: str) -> Iterator[tuple[str, str, str, str | None, str]]:
    """Yield (ts_local_naive, component, severity, hresult, message) per line.

    Only 'error'/'warn' lines are emitted; informational noise is skipped to
    keep the timeline focused.
    """
    for line in text.splitlines():
        m = _LINE.match(line)
        if not m:
            continue
        msg = m["msg"].strip()
        hr = _HRESULT.search(msg)
        if _FAIL.search(msg) or hr:
            severity = "error"
        elif _WARN.search(msg):
            severity = "warn"
        else:
            continue  # skip informational noise
        yield (_ts(m), m["comp"], severity, ("0x" + hr.group(1)) if hr else None, msg)
