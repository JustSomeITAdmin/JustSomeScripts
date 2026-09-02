"""Discover the diagnosed device's UTC offset from the package.

Priority:
  1. `ReportUtcOffset` meta in battery-report.html / energy-report.html — an
     explicit numeric offset written by powercfg (most reliable, machine-parseable).
  2. The "Time Zone" name in msinfo32.log, mapped through a small table of common
     zones (the name encodes DST, e.g. "Eastern Daylight Time" = UTC-4).

Returns (offset_minutes, tz_name, source) or (None, None, None).
"""

from __future__ import annotations

import re
import zipfile
from pathlib import Path

from rca.timeutil import parse_offset

_REPORT_OFFSET_RE = re.compile(
    r'ReportUtcOffset"\s+content="([+-]?\d{1,2}:\d{2})"', re.I
)
_MSINFO_TZ_RE = re.compile(r"Time Zone\s+(.+)")

# Common Windows zone display names -> offset minutes. The DST variants ("…
# Daylight Time") already bake in the +1h, so a static map is correct for the
# moment the report was generated.
_NAME_TO_OFFSET = {
    "eastern daylight time": -240, "eastern standard time": -300,
    "central daylight time": -300, "central standard time": -360,
    "mountain daylight time": -360, "mountain standard time": -420,
    "pacific daylight time": -420, "pacific standard time": -480,
    "atlantic daylight time": -180, "atlantic standard time": -240,
    "alaskan daylight time": -480, "alaskan standard time": -540,
    "hawaiian standard time": -600,
    "utc": 0, "coordinated universal time": 0, "gmt standard time": 0,
}


def detect_offset(zip_path: Path) -> tuple[int | None, str | None, str | None]:
    with zipfile.ZipFile(zip_path) as z:
        names = z.namelist()

        # 1) battery / energy report explicit offset
        for needle in ("battery-report", "energy-report"):
            for n in names:
                if needle in n.lower() and n.lower().endswith((".html", ".htm")):
                    text = z.read(n).decode("utf-8", "ignore")
                    m = _REPORT_OFFSET_RE.search(text)
                    if m:
                        off = parse_offset(m.group(1))
                        if off is not None:
                            return off, None, f"{needle} ReportUtcOffset"

        # 2) msinfo32 Time Zone name
        for n in names:
            if "msinfo32" in n.lower() and n.lower().endswith(".log"):
                raw = z.read(n)
                for enc in ("utf-16", "utf-8", "cp1252"):
                    try:
                        text = raw.decode(enc)
                        break
                    except UnicodeDecodeError:
                        text = ""
                if "Time Zone" not in text:
                    continue
                m = _MSINFO_TZ_RE.search(text)
                if m:
                    name = m.group(1).strip()
                    off = _NAME_TO_OFFSET.get(name.lower())
                    return off, name, "msinfo32 Time Zone"

    return None, None, None
