"""Run parsers over catalogued artifacts and write the unified `events` table.

Two parser flavors:
  * TEXT parsers (e.g. IME) get the decoded text + a can_parse() sniff.
  * FILE parsers (e.g. evtx) need a real file on disk and do their own reading
    (shelling out to PowerShell), so the artifact is materialized from the ZIP
    first.

Add a module to TEXT_PARSERS or FILE_PARSERS keyed by category to extend.
"""

from __future__ import annotations

import sqlite3
import zipfile
from pathlib import Path

from rca import config
from rca.parsers import evtx, ime, msi
from rca.timeutil import normalize

# A category can have several text parsers; the first whose can_parse() matches
# the content wins (IME logs are CMTrace; the per-app *.msi.log are MSI verbose).
TEXT_PARSERS = {"ime_log": [ime, msi]}
FILE_PARSERS = {"eventlog": evtx}
ALL_CATEGORIES = (*TEXT_PARSERS, *FILE_PARSERS)

_SAMPLE_BYTES = 4096


def _decode(b: bytes) -> str:
    """Decode log bytes, honoring a UTF-16/UTF-8 BOM (MSI logs are UTF-16)."""
    if b[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return b.decode("utf-16", errors="replace")
    if b[:3] == b"\xef\xbb\xbf":
        return b.decode("utf-8-sig", errors="replace")
    return b.decode("utf-8", errors="replace")


def _materialize(conn: sqlite3.Connection, row: sqlite3.Row, zf: zipfile.ZipFile,
                 case_id: int) -> Path:
    """Ensure an artifact's bytes are on disk; return the path."""
    if row["materialized"] and row["raw_path"] and Path(row["raw_path"]).exists():
        return Path(row["raw_path"])
    dest = config.case_raw_dir(case_id) / row["rel_path"]
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(zf.read(row["rel_path"]))
    conn.execute(
        "UPDATE artifacts SET materialized = 1, raw_path = ? WHERE id = ?",
        (str(dest), row["id"]),
    )
    return dest


def _set_status(conn, artifact_id: int, status: str, parser_name: str | None) -> None:
    conn.execute(
        "UPDATE artifacts SET parsed_status = ?, parser_name = ? WHERE id = ?",
        (status, parser_name, artifact_id),
    )


def _insert_events(conn, case_id, bundle_id, artifact_id, events, offset_min) -> int:
    rows = []
    for e in events:
        ts_utc, ts_local = normalize(e.ts_raw, e.ts_kind, offset_min)
        rows.append((case_id, bundle_id, artifact_id, ts_utc, ts_local, e.source,
                     e.severity, e.event_code, e.actor, e.message, e.raw_ref))
    conn.executemany(
        """INSERT INTO events
           (case_id, bundle_id, artifact_id, ts_utc, ts_local, source, severity,
            event_code, actor, message, raw_ref)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        rows,
    )
    return len(events)


def parse_case(
    conn: sqlite3.Connection,
    case_id: int,
    categories: tuple[str, ...] = ("ime_log",),
    reparse: bool = False,
) -> dict:
    """Parse matching artifacts for a case into events. Returns a summary."""
    if "all" in categories:
        cats = ALL_CATEGORIES
    else:
        cats = tuple(c for c in categories if c in ALL_CATEGORIES)
    if not cats:
        return {"error": f"no parser for categories {categories}"}

    placeholders = ",".join("?" * len(cats))
    bundles = conn.execute(
        "SELECT * FROM bundles WHERE case_id = ? ORDER BY id", (case_id,)
    ).fetchall()

    summary = {"artifacts_parsed": 0, "artifacts_skipped": 0, "artifacts_error": 0,
               "events": 0, "by_source": {}}

    for b in bundles:
        status_filter = "" if reparse else "AND a.parsed_status = 'pending'"
        # .evtx inside the expanded mdmlogs CAB (category 'mdm') carry the MDM
        # policy/CSP channels (DeviceManagement-Enterprise-Diagnostics-Provider);
        # route them to the evtx parser alongside the top-level eventlog files.
        mdm_evtx = ("OR (a.category = 'mdm' AND lower(a.rel_path) LIKE '%.evtx')"
                    if "eventlog" in cats else "")
        rows = conn.execute(
            f"""SELECT * FROM artifacts a
                WHERE a.bundle_id = ? AND (a.category IN ({placeholders}) {mdm_evtx})
                      AND a.size > 0 {status_filter}
                ORDER BY a.rel_path""",
            (b["id"], *cats),
        ).fetchall()
        if not rows:
            continue

        offset_min = b["tz_offset_minutes"]
        zf = zipfile.ZipFile(b["source_path"]) if Path(b["source_path"]).exists() else None
        try:
            for row in rows:
                if reparse:
                    conn.execute("DELETE FROM events WHERE artifact_id = ?", (row["id"],))
                cat = "eventlog" if row["category"] == "mdm" else row["category"]
                try:
                    if cat in TEXT_PARSERS:
                        n, status, name = _run_text(conn, row, zf, case_id, b["id"], offset_min)
                    else:
                        n, status, name = _run_file(conn, row, zf, case_id, b["id"], offset_min)
                except Exception as exc:  # isolate one bad artifact
                    _set_status(conn, row["id"], "error", f"{type(exc).__name__}: {exc}"[:200])
                    summary["artifacts_error"] += 1
                    continue

                _set_status(conn, row["id"], status, name)
                conn.commit()  # cap the write-lock window per artifact, not per case
                if status == "parsed":
                    summary["artifacts_parsed"] += 1
                    summary["events"] += n
                    summary["by_source"][name] = summary["by_source"].get(name, 0) + n
                elif status == "skipped":
                    summary["artifacts_skipped"] += 1
        finally:
            if zf is not None:
                zf.close()

    conn.commit()
    return summary


def _run_text(conn, row, zf, case_id, bundle_id, offset_min):
    if row["materialized"] and row["raw_path"]:
        text = _decode(Path(row["raw_path"]).read_bytes())
    elif zf is not None:
        text = _decode(zf.read(row["rel_path"]))
    else:
        raise RuntimeError("source ZIP unavailable")

    sample = text[:_SAMPLE_BYTES]
    parser = next((p for p in TEXT_PARSERS[row["category"]]
                   if p.can_parse(row["rel_path"], sample)), None)
    if parser is None:
        return 0, "skipped", "no-text-parser"
    events = list(parser.parse(text, row["rel_path"]))
    _insert_events(conn, case_id, bundle_id, row["id"], events, offset_min)
    return len(events), "parsed", parser.SOURCE


def _run_file(conn, row, zf, case_id, bundle_id, offset_min):
    parser = FILE_PARSERS["eventlog" if row["category"] == "mdm" else row["category"]]
    if zf is None and not (row["materialized"] and row["raw_path"]):
        raise RuntimeError("source ZIP unavailable")
    disk_path = _materialize(conn, row, zf, case_id)
    events = list(parser.parse_file(disk_path, row["rel_path"]))
    _insert_events(conn, case_id, bundle_id, row["id"], events, offset_min)
    return len(events), "parsed", parser.SOURCE
