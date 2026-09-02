"""Shared dataclasses for normalized records.

`Event` is the in-memory shape parsers emit. The orchestrator stamps on the
case/bundle/artifact ids and writes it to the `events` table — the one unified
timeline every source normalizes into.
"""

from __future__ import annotations

from dataclasses import dataclass

# CMTrace `type` attribute -> our severity vocabulary.
SEVERITY_INFO = "info"
SEVERITY_WARN = "warn"
SEVERITY_ERROR = "error"
SEVERITY_CRITICAL = "critical"

# For ordering "worst severity" in aggregates.
SEVERITY_RANK = {
    SEVERITY_INFO: 0,
    SEVERITY_WARN: 1,
    SEVERITY_ERROR: 2,
    SEVERITY_CRITICAL: 3,
}


@dataclass
class Event:
    source: str                 # IME | Defender | evtx | ...
    message: str
    ts_raw: str | None = None   # timestamp as the source recorded it
    ts_kind: str = "local"      # 'local' (device wall clock) or 'utc'
    severity: str = SEVERITY_INFO
    event_code: str | None = None
    actor: str | None = None    # app GUID, script id, process, user
    raw_ref: str | None = None  # back-pointer into the source artifact (e.g. "line=1234")
