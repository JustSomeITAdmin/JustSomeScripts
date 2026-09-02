"""Intune Management Extension parser.

Sits on top of the CMTrace reader and adds IME-specific semantics:
  * extract the **app id** by context (`App with id:`, `"ApplicationId"`,
    `"AppId"`) — never by blind GUID matching, because the most frequent GUID
    in these logs is actually the *user* id.
  * extract an **error/exit code** (HRESULT, PowerShell exit code, WinHTTP error).
  * decode the per-app **ReportingState** JSON into a structured outcome and
    escalate severity when an error code is present.

Only CMTrace-format engine logs are handled here (IntuneManagementExtension.log,
AppWorkload.log, AgentExecutor.log, ...). The per-app `*.msi.log` files are raw
Windows Installer logs — a separate parser, later.
"""

from __future__ import annotations

import json
import re
from typing import Iterator

from rca.models import SEVERITY_ERROR, SEVERITY_WARN, Event
from rca.parsers import cmtrace
from rca.util import hresult_hex

SOURCE = "IME"

_GUID = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"

_APP_ID_RES = [
    re.compile(r"App with id:\s*(" + _GUID + r")"),
    re.compile(r'"ApplicationId"\s*:\s*"(' + _GUID + r')"'),
    re.compile(r'"AppId"\s*:\s*"(' + _GUID + r')"'),
]
_HRESULT_RE = re.compile(r"0x[0-9A-Fa-f]{8}")
_EXIT_RE = re.compile(r"exit code is\s*(-?\d+)", re.I)
_WINHTTP_RE = re.compile(r"error\s+(\d{4,5})\b", re.I)
_REPORTING_RE = re.compile(r"ReportingState:\s*(\{.*\})", re.S)

# ReportingState error fields, in the order we prefer to surface them.
_RS_ERROR_FIELDS = (
    "EnforcementErrorCode",
    "DetectionErrorCode",
    "ApplicabilityErrorCode",
)


def can_parse(filename: str, sample_text: str) -> bool:
    return cmtrace.looks_like_cmtrace(sample_text)


def _extract_app_id(msg: str) -> str | None:
    for rx in _APP_ID_RES:
        m = rx.search(msg)
        if m:
            return m.group(1).lower()
    return None


def _extract_code(msg: str) -> str | None:
    m = _HRESULT_RE.search(msg)
    if m:
        return m.group(0).lower()
    m = _EXIT_RE.search(msg)
    if m:
        return f"exit={m.group(1)}"
    m = _WINHTTP_RE.search(msg)
    if m:
        return f"winhttp={m.group(1)}"
    return None


def _reporting_state(msg: str) -> dict | None:
    m = _REPORTING_RE.search(msg)
    if not m:
        return None
    try:
        return json.loads(m.group(1))
    except (json.JSONDecodeError, ValueError):
        return None


def parse(text: str, filename: str = "") -> Iterator[Event]:
    for rec in cmtrace.iter_records(text):
        msg = rec.message
        severity = rec.severity
        actor = _extract_app_id(msg)
        code = _extract_code(msg)

        rs = _reporting_state(msg)
        if rs is not None:
            actor = (rs.get("ApplicationId") or actor or "").lower() or None
            for field in _RS_ERROR_FIELDS:
                val = rs.get(field)
                if val:  # non-null, non-zero
                    # ReportingState stores HRESULTs as signed ints — normalize
                    # to 0xXXXXXXXX so codes are readable + error_map-ready.
                    code = hresult_hex(int(val)) if isinstance(val, int) else str(val)
                    severity = SEVERITY_ERROR
                    break

        # Escalate clearly-failed script/install lines that IME logs at type=1.
        if code:
            if code.startswith("exit=") and code != "exit=0":
                severity = SEVERITY_ERROR
            elif code.startswith("0x") and code != "0x00000000" and severity == "info":
                severity = SEVERITY_WARN

        yield Event(
            source=SOURCE,
            message=msg,
            ts_raw=rec.ts,          # CMTrace records device-local wall time
            ts_kind="local",
            severity=severity,
            event_code=code,
            actor=actor,
            raw_ref=f"line={rec.line}",
        )
