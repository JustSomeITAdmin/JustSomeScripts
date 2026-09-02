"""Windows Installer (MSI) verbose-log parser.

These are the per-app `*.msi.log` files the IME drops next to its engine logs.
They're verbose and mostly noise, so this parser is *selective*: it emits the
install start, any hard failure lines (Return value 3, failed custom actions),
and the authoritative final result code — not every line.

Format (UTF-16):
    === Verbose logging started: 6/15/2026  9:32:58  Build type: ... ===
    MSI (c) (58:1C) [09:32:58:278]: <message>
The header carries the date; each line carries a bracketed device-local time.

Why this matters for RCA: an MSI that returns 0 while Intune reports the app as
failed (e.g. 0x87D1041C "not detected after install") points at the detection
rule, not the installer.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Iterator

from rca.models import SEVERITY_ERROR, SEVERITY_INFO, SEVERITY_WARN, Event

SOURCE = "MSI"

_HEADER_RE = re.compile(r"Verbose logging started:\s*(\d+)/(\d+)/(\d+)\s+(\d+):(\d+):(\d+)")
_TIME_RE = re.compile(r"\[(\d{2}):(\d{2}):(\d{2}):(\d{3})\]")
_PRODUCT_RE = re.compile(r"ProductName\s*=\s*([^,\r\n]+)")
_VERSION_RE = re.compile(r"ProductVersion\s*=\s*([^,\r\n]+)")
_STATUS_RE = re.compile(r"success or error status:\s*(\d+)")
_MAIN_RE = re.compile(r"MainEngineThread is returning\s*(\d+)")
_RV3_RE = re.compile(r"Return value 3\b")
_CA_ERR_RE = re.compile(r"CustomAction (\S+) returned actual error code (\d+)")

# Common MSI/Win32 install result codes.
MSI_CODES = {
    "0": "success",
    "1603": "fatal error during installation",
    "1605": "product is not installed",
    "1618": "another installation already in progress",
    "1619": "installation package could not be opened",
    "1620": "installation package could not be opened (invalid)",
    "1638": "another version of this product is already installed",
    "1641": "success, reboot initiated",
    "3010": "success, reboot required",
}
_SUCCESS_CODES = {"0", "1641", "3010"}


def can_parse(filename: str, sample_text: str) -> bool:
    return "Verbose logging started" in sample_text or "MSI (" in sample_text


def parse(text: str, filename: str = "") -> Iterator[Event]:
    lines = text.splitlines()

    base = None       # (Y, M, D)
    header_ts = None
    for ln in lines:
        h = _HEADER_RE.search(ln)
        if h:
            mo, d, y, hh, mi, ss = (int(x) for x in h.groups())
            base = (y, mo, d)
            header_ts = f"{y:04d}-{mo:02d}-{d:02d}T{hh:02d}:{mi:02d}:{ss:02d}.000000"
            break

    def ts_for(line: str) -> str | None:
        m = _TIME_RE.search(line)
        if m and base:
            hh, mi, ss, ms = m.groups()
            y, mo, d = base
            return f"{y:04d}-{mo:02d}-{d:02d}T{hh}:{mi}:{ss}.{ms}000"
        return header_ts

    product = version = None
    for ln in lines:
        if product is None and (m := _PRODUCT_RE.search(ln)):
            product = m.group(1).strip()
        if version is None and (m := _VERSION_RE.search(ln)):
            version = m.group(1).strip()
        if product and version:
            break

    label = product or Path(filename).name
    actor = label[:60]

    # 1) install start
    start_msg = f"MSI install started: {label}" + (f" v{version}" if version else "")
    yield Event(SOURCE, start_msg, ts_raw=header_ts, ts_kind="local",
                severity=SEVERITY_INFO, actor=actor, raw_ref="header")

    # 2) hard-failure lines + capture the authoritative final code
    status_code = main_code = None
    status_ts = None
    for i, ln in enumerate(lines, 1):
        if _RV3_RE.search(ln):
            yield Event(SOURCE, ln.strip()[:300], ts_raw=ts_for(ln), ts_kind="local",
                        severity=SEVERITY_WARN, event_code="3", actor=actor,
                        raw_ref=f"line={i}")
        if m := _CA_ERR_RE.search(ln):
            yield Event(SOURCE, ln.strip()[:300], ts_raw=ts_for(ln), ts_kind="local",
                        severity=SEVERITY_ERROR, event_code=m.group(2), actor=actor,
                        raw_ref=f"line={i}")
        if m := _STATUS_RE.search(ln):
            status_code, status_ts = m.group(1), ts_for(ln)
        elif m := _MAIN_RE.search(ln):
            main_code = m.group(1)

    # 3) authoritative outcome
    code = status_code if status_code is not None else main_code
    if code is not None:
        meaning = MSI_CODES.get(code, "")
        sev = SEVERITY_INFO if code in _SUCCESS_CODES else SEVERITY_ERROR
        msg = f"Installation result: {code}" + (f" ({meaning})" if meaning else "")
        yield Event(SOURCE, msg, ts_raw=status_ts or header_ts, ts_kind="local",
                    severity=sev, event_code=code, actor=actor, raw_ref="result")
