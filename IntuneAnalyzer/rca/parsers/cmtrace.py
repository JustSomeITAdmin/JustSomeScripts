"""Parser for the CMTrace log format used by the Intune Management Extension.

A record looks like:

    <![LOG[<message>]LOG]!><time="18:02:43.1773049" date="6-17-2026"
        component="IntuneManagementExtension" context="" type="1"
        thread="25" file="">

`type` follows the CMTrace convention: 1=info, 2=warning, 3=error.
This module just yields structured records; semantic extraction (app ids,
error codes) lives in the IME parser on top of it.
"""

from __future__ import annotations

import bisect
import re
from dataclasses import dataclass
from typing import Iterator

from rca.models import SEVERITY_ERROR, SEVERITY_INFO, SEVERITY_WARN

_RECORD_RE = re.compile(
    r"<!\[LOG\[(?P<msg>.*?)\]LOG\]!>"
    r'<time="(?P<time>[^"]*)"\s+date="(?P<date>[^"]*)"'
    r'\s+component="(?P<comp>[^"]*)"'
    r'(?:\s+context="[^"]*")?'
    r'\s+type="(?P<type>[^"]*)"',
    re.S,
)

_TYPE_TO_SEVERITY = {"1": SEVERITY_INFO, "2": SEVERITY_WARN, "3": SEVERITY_ERROR}


@dataclass
class CmRecord:
    message: str
    ts: str | None          # device-local wall time (CMTrace has no timezone)
    component: str
    severity: str
    line: int


def looks_like_cmtrace(text: str) -> bool:
    """Cheap sniff: CMTrace files open with (optional BOM then) `<![LOG[`."""
    head = text.lstrip("﻿")[:512]
    return "<![LOG[" in head and "]LOG]!>" in head


def _parse_ts(date_s: str, time_s: str) -> str | None:
    """Combine CMTrace date (`M-D-YYYY`) + time (`HH:MM:SS.fffffff`) into ISO.

    These are device-local timestamps with no timezone, so we keep them naive.
    """
    try:
        mo, d, y = (int(x) for x in date_s.split("-"))
        hms, _, frac = time_s.partition(".")
        h, mi, s = (int(x) for x in hms.split(":"))
        micros = int((frac + "000000")[:6]) if frac else 0
        return f"{y:04d}-{mo:02d}-{d:02d}T{h:02d}:{mi:02d}:{s:02d}.{micros:06d}"
    except (ValueError, AttributeError):
        return None


def iter_records(text: str) -> Iterator[CmRecord]:
    """Yield CmRecord for every CMTrace entry in `text`."""
    # Precompute newline offsets so we can map a match to a 1-based line number.
    nl_offsets = [m.start() for m in re.finditer("\n", text)]
    for m in _RECORD_RE.finditer(text):
        line = bisect.bisect_right(nl_offsets, m.start()) + 1
        yield CmRecord(
            message=m.group("msg").strip(),
            ts=_parse_ts(m.group("date"), m.group("time")),
            component=m.group("comp"),
            severity=_TYPE_TO_SEVERITY.get(m.group("type"), SEVERITY_INFO),
            line=line,
        )
