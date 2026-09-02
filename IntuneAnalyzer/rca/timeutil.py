"""Timestamp normalization across sources.

The unified timeline has two clocks:
  * IME CMTrace logs record device-*local* wall time with no timezone.
  * evtx records true UTC.

To correlate them we convert everything to a single canonical UTC axis, and to
keep it readable for a tech we also keep the device-local rendering. A bundle's
UTC offset (e.g. -240 min for EDT) is discovered at ingest; given it, we can map
either kind of raw timestamp to both (ts_utc, ts_local).

A fixed offset is correct for any window that doesn't straddle a DST boundary,
which covers essentially all RCA windows. (Crossing a DST change would need the
IANA zone — a documented future enhancement.)
"""

from __future__ import annotations

import re
from datetime import datetime, timedelta

_OFFSET_RE = re.compile(r"^\s*([+-]?)(\d{1,2}):?(\d{2})\s*$")


def parse_offset(text: str | None) -> int | None:
    """Parse an offset like '-4:00', '+05:30', '-0500' into minutes."""
    if not text:
        return None
    m = _OFFSET_RE.match(text)
    if not m:
        return None
    sign = -1 if m.group(1) == "-" else 1
    return sign * (int(m.group(2)) * 60 + int(m.group(3)))


def format_offset(minutes: int | None) -> str:
    """Render minutes as 'UTC-4' / 'UTC+5:30' / 'UTC' for labels."""
    if minutes is None:
        return "UTC?"
    if minutes == 0:
        return "UTC"
    sign = "+" if minutes > 0 else "-"
    h, m = divmod(abs(minutes), 60)
    return f"UTC{sign}{h}" if m == 0 else f"UTC{sign}{h}:{m:02d}"


def _to_naive(ts: str) -> datetime | None:
    """Parse an ISO timestamp to a naive datetime (drops any 'Z'/offset).

    Tolerates .NET's 7-digit fractional seconds by trimming to 6.
    """
    if not ts:
        return None
    s = ts.strip().rstrip("Z")
    if "." in s:
        head, frac = s.split(".", 1)
        frac = re.sub(r"[^0-9].*$", "", frac)  # strip any trailing offset chars
        s = f"{head}.{frac[:6]}"
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        return None


def _fmt(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%f")


def normalize(ts_raw: str | None, ts_kind: str,
              offset_min: int | None) -> tuple[str | None, str | None]:
    """Map a raw timestamp to (ts_utc, ts_local).

    ts_kind is 'local' (device wall clock) or 'utc'. When the offset is unknown,
    only the natively-known clock is returned; the other is None.
    """
    dt = _to_naive(ts_raw) if ts_raw else None
    if dt is None:
        return None, None

    if ts_kind == "utc":
        ts_utc = _fmt(dt) + "Z"
        ts_local = _fmt(dt + timedelta(minutes=offset_min)) if offset_min is not None else None
        return ts_utc, ts_local

    # ts_kind == 'local'
    ts_local = _fmt(dt)
    ts_utc = (_fmt(dt - timedelta(minutes=offset_min)) + "Z") if offset_min is not None else None
    return ts_utc, ts_local
