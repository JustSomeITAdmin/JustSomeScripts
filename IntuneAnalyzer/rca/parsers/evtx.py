"""Windows event log (.evtx) parser, backed by PowerShell Get-WinEvent.

evtx is binary and best read by native Windows tooling, so this parser is a
"file parser": it takes a path to a materialized .evtx, shells out to
read_evtx.ps1, and maps the JSON it returns into Events.

Unlike the IME CMTrace logs (device-local, naive timestamps), evtx records carry
true UTC instants — read_evtx.ps1 emits them with a trailing 'Z'.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Iterator

from rca.models import (
    SEVERITY_CRITICAL,
    SEVERITY_ERROR,
    SEVERITY_INFO,
    SEVERITY_WARN,
    Event,
)

SOURCE = "evtx"

_SCRIPT = Path(__file__).resolve().parent.parent / "ps" / "read_evtx.ps1"
_POWERSHELL = (
    Path(os.environ.get("WINDIR", r"C:\Windows"))
    / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
)

# Get-WinEvent Level -> our severity vocabulary.
_LEVEL_TO_SEVERITY = {
    1: SEVERITY_CRITICAL,
    2: SEVERITY_ERROR,
    3: SEVERITY_WARN,
    4: SEVERITY_INFO,
    0: SEVERITY_INFO,
    5: SEVERITY_INFO,  # Verbose
}


def _ps_exe() -> str:
    return str(_POWERSHELL) if _POWERSHELL.exists() else "powershell"


# Channels whose INFO-level events carry diagnostic verdicts we depend on:
# System holds User32/1074 (names every restart's initiating process) and the
# TPM-WMI Secure Boot apply/report events; BitLocker Management holds the
# suspend/resume trail. Field-proven three times that filtering these to
# warn+error hides the answer.
_ALL_LEVEL_CHANNELS = ("system events.evtx", "bitlocker_management", "tpm",
                       # Hello provisioning/success and NGC key registration are
                       # info-level; without them a PIN rebuild is invisible (field case).
                       "helloforbusiness", "user device registration")


def parse_file(
    disk_path: Path,
    rel_path: str = "",
    levels: tuple[int, ...] | None = (1, 2, 3),
    max_events: int = 20000,
) -> Iterator[Event]:
    """Read a materialized .evtx via PowerShell and yield normalized Events."""
    low = (rel_path or str(disk_path)).lower()
    if levels == (1, 2, 3) and any(k in low for k in _ALL_LEVEL_CHANNELS):
        # No Level filter at all: classic providers (Service Control Manager
        # 7036 service start/stop, User32, EventLog) log at Level 0 (LogAlways),
        # which a 1-4 filter silently drops — that hid every service event and
        # made "no Zscaler services ever ran" look true in a field case.
        levels = None
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as tf:
        out_json = Path(tf.name)
    try:
        cmd = [
            _ps_exe(), "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", str(_SCRIPT),
            "-Path", str(disk_path),
            "-Out", str(out_json),
            "-Max", str(max_events),
        ]
        # Pass as a single comma-joined token; the script splits it. Array
        # params don't bind reliably through PowerShell's -File argument parser.
        cmd += ["-Levels", ",".join(str(x) for x in levels) if levels else ""]

        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        raw = out_json.read_text(encoding="utf-8-sig") if out_json.exists() else ""
        if not raw.strip():
            raise RuntimeError(
                f"empty output from Get-WinEvent (rc={proc.returncode}): "
                f"{(proc.stderr or '').strip()[:300]}"
            )
        data = json.loads(raw)
        if isinstance(data, dict) and "error" in data:
            raise RuntimeError(f"Get-WinEvent: {data['error']}")
    finally:
        out_json.unlink(missing_ok=True)

    for rec in data:
        level = rec.get("Level")
        provider = rec.get("Provider") or "?"
        eid = rec.get("Id")
        message = rec.get("Message") or "(no rendered message)"
        yield Event(
            source=SOURCE,
            # Put provider+EventID up front so the timeline row is self-describing.
            message=f"[{provider}/{eid}] {message}",
            ts_raw=rec.get("TimeCreated"),   # Get-WinEvent gives true UTC
            ts_kind="utc",
            severity=_LEVEL_TO_SEVERITY.get(level, SEVERITY_INFO),
            event_code=str(eid) if eid is not None else None,
            actor=provider,
            raw_ref=f"RecordId={rec.get('RecordId')}",
        )
