"""On-demand ETL processing.

ETL traces are binary and expensive to decode, so they're never touched by the
normal `parse`. `rca etl` materializes the WindowsUpdate *.etl files, merges them
with Get-WindowsUpdateLog, and loads the significant (warning/error) lines into
the timeline as source 'WU'. This is the servicing view — exactly what an "after
the June update" symptom needs.

Timestamps in the merged log are the *converting* machine's local time, so we
convert them to UTC with this machine's offset, then render device-local using
the bundle's offset (consistent with the rest of the timeline).
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sqlite3
import zipfile
from datetime import datetime
from pathlib import Path

from rca import config
from rca.parsers.wulog import parse_wulog
from rca.timeutil import normalize

_PS = Path(os.environ.get("WINDIR", r"C:\Windows")) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
_CONVERT = Path(__file__).resolve().parent / "ps" / "convert_wu_etl.ps1"


def _converter_offset_min() -> int:
    off = datetime.now().astimezone().utcoffset()
    return int(off.total_seconds() // 60) if off else 0


def _ps_exe() -> str:
    return str(_PS) if _PS.exists() else "powershell"


def load_wu(conn: sqlite3.Connection, case_id: int, reparse: bool = False) -> dict:
    """Decode WindowsUpdate ETLs and load their warnings/errors as 'WU' events."""
    bundles = conn.execute(
        "SELECT * FROM bundles WHERE case_id = ? ORDER BY id", (case_id,)).fetchall()
    summary = {"etl_files": 0, "events": 0, "log_kb": 0, "note": None}
    conv_off = _converter_offset_min()

    for b in bundles:
        status_filter = "" if reparse else "AND parsed_status = 'pending'"
        rows = conn.execute(
            f"""SELECT * FROM artifacts
                WHERE bundle_id = ? AND category = 'wu_etl' AND ext = '.etl'
                      AND LOWER(rel_path) LIKE '%windowsupdate_etl%' AND size > 0 {status_filter}
                ORDER BY rel_path""", (b["id"],)).fetchall()
        if not rows:
            continue

        work = config.case_raw_dir(case_id) / "wuetl"
        if work.exists():
            shutil.rmtree(work, ignore_errors=True)
        work.mkdir(parents=True, exist_ok=True)

        # materialize the .etl files
        src_zip = b["source_path"]
        if not Path(src_zip).exists():
            summary["note"] = "source ZIP unavailable"
            continue
        with zipfile.ZipFile(src_zip) as z:
            for r in rows:
                (work / Path(r["rel_path"]).name).write_bytes(z.read(r["rel_path"]))
        summary["etl_files"] += len(rows)

        # convert
        log_path = work / "WindowsUpdate.merged.log"
        proc = subprocess.run(
            [_ps_exe(), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(_CONVERT),
             "-EtlDir", str(work), "-Out", str(log_path)],
            capture_output=True, text=True, timeout=900)
        if not log_path.exists():
            summary["note"] = f"conversion failed: {(proc.stdout or proc.stderr).strip()[:200]}"
            shutil.rmtree(work, ignore_errors=True)
            continue
        summary["log_kb"] += int(log_path.stat().st_size / 1024)

        # parse + load
        text = log_path.read_text(encoding="utf-8", errors="replace")
        device_off = b["tz_offset_minutes"]
        events = []
        for ts_local_naive, comp, severity, code, msg in parse_wulog(text):
            ts_utc, _ = normalize(ts_local_naive, "local", conv_off)
            ts_disp = None
            if ts_utc and device_off is not None:
                _, ts_disp = normalize(ts_utc, "utc", device_off)
            events.append((case_id, b["id"], ts_utc, ts_disp, "WU", severity, code,
                           comp, msg[:300], "wulog"))

        if reparse:
            conn.execute("DELETE FROM events WHERE case_id = ? AND source = 'WU'", (case_id,))
        conn.executemany(
            """INSERT INTO events
               (case_id, bundle_id, ts_utc, ts_local, source, severity, event_code,
                actor, message, raw_ref)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""", events)
        for r in rows:
            conn.execute("UPDATE artifacts SET parsed_status='parsed', parser_name='WU' WHERE id=?",
                         (r["id"],))
        summary["events"] += len(events)

        # keep the merged log for reference; drop the bulky .etl copies
        for f in work.glob("*.etl"):
            f.unlink(missing_ok=True)

    conn.commit()
    return summary
