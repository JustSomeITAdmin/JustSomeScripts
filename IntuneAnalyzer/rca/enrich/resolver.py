"""Resolve a case's app GUIDs to names, caching in app_map (cross-case).

The cache means a GUID is fetched from Graph once and reused for every future
case — important when you're working offline or rate-limited.
"""

from __future__ import annotations

import sqlite3

from rca.enrich import graph
from rca.util import now_utc_iso

# Reuse the GUID-shaped filter so we only try to resolve real app ids.
_GUID_LIKE = "________-____-____-____-____________"


def case_app_guids(conn: sqlite3.Connection, case_id: int,
                   errors_only: bool = False) -> list[str]:
    having = "HAVING SUM(severity IN ('error','critical')) > 0" if errors_only else ""
    rows = conn.execute(
        f"""SELECT actor FROM events
            WHERE case_id = ? AND actor IS NOT NULL
                  AND LENGTH(actor) = 36 AND actor LIKE '{_GUID_LIKE}'
            GROUP BY actor {having}
            ORDER BY actor""",
        (case_id,),
    ).fetchall()
    return [r["actor"] for r in rows]


def upsert(conn: sqlite3.Connection, guid: str, display_name: str | None,
           publisher: str | None = None, app_type: str | None = None,
           source: str = "graph") -> None:
    conn.execute(
        """INSERT INTO app_map (app_guid, display_name, publisher, app_type, source, fetched_utc)
           VALUES (?, ?, ?, ?, ?, ?)
           ON CONFLICT(app_guid) DO UPDATE SET
             display_name=excluded.display_name, publisher=excluded.publisher,
             app_type=excluded.app_type, source=excluded.source,
             fetched_utc=excluded.fetched_utc""",
        (guid, display_name, publisher, app_type, source, now_utc_iso()),
    )


def resolve_case(conn: sqlite3.Connection, case_id: int, force: bool = False,
                 errors_only: bool = False, interactive: bool = True,
                 device_code_prompt=print, progress_cb=None) -> dict:
    """Resolve a case's app GUIDs via Graph ($batch), caching results.

    progress_cb(done, total) is called after each batch. Returns a summary.
    """
    guids = case_app_guids(conn, case_id, errors_only=errors_only)
    if not guids:
        return {"total": 0, "resolved": 0, "cached": 0, "not_found": 0, "errors": 0}

    cached = {r["app_guid"] for r in conn.execute("SELECT app_guid FROM app_map")}
    todo = guids if force else [g for g in guids if g not in cached]

    summary = {"total": len(guids), "resolved": 0,
               "cached": len(guids) - len(todo), "not_found": 0, "errors": 0}
    if not todo:
        if progress_cb:
            progress_cb(0, 0)
        return summary

    token = graph.get_token(interactive=interactive, device_code_prompt=device_code_prompt)

    done = 0
    for i in range(0, len(todo), graph.BATCH_SIZE):
        chunk = todo[i:i + graph.BATCH_SIZE]
        try:
            results = graph.resolve_batch(token, chunk)
        except Exception:
            summary["errors"] += len(chunk)
            done += len(chunk)
            if progress_cb:
                progress_cb(done, len(todo))
            continue
        for g in chunk:
            if g not in results:                       # non-404 error for this id
                summary["errors"] += 1
            elif results[g] is None:                   # 404
                upsert(conn, g, "(not found in Intune)", source="graph-404")
                summary["not_found"] += 1
            else:
                info = results[g]
                upsert(conn, g, info["display_name"], info["publisher"], info["app_type"])
                summary["resolved"] += 1
        conn.commit()
        done += len(chunk)
        if progress_cb:
            progress_cb(done, len(todo))
    return summary
