"""Read-only tools the agent calls to investigate a case.

Every tool queries the normalized SQLite tables and returns compact,
JSON-serializable data (bounded row counts, truncated text) so the model's
context stays small and cheap — the agent never ingests raw logs. This is what
makes a local 7B model viable for analyzing a 2 GB package.

build_tools(conn, case_id) returns (specs, dispatch): the OpenAI-style tool
schemas to advertise, and a name->callable map bound to this case.
"""

from __future__ import annotations

import sqlite3

from rca.enrich import detection

_MSG = 200   # max message chars returned to the model


def _clip(s, n=_MSG):
    s = (s or "").replace("\n", " ")
    return s if len(s) <= n else s[: n - 1] + "…"


def build_tools(conn: sqlite3.Connection, case_id: int):
    guid_like = "________-____-____-____-____________"

    def case_overview(_args):
        c = conn.execute("SELECT symptom_text, status FROM cases WHERE id = ?", (case_id,)).fetchone()
        b = conn.execute(
            """SELECT machine_name, collected_utc, tz_name, tz_offset_minutes
               FROM bundles WHERE case_id = ? ORDER BY id LIMIT 1""", (case_id,)).fetchone()
        by_source = {r["source"]: r["n"] for r in conn.execute(
            "SELECT source, COUNT(*) n FROM events WHERE case_id = ? GROUP BY source", (case_id,))}
        n_find = conn.execute("SELECT COUNT(*) n FROM findings WHERE case_id = ?", (case_id,)).fetchone()["n"]
        n_apps = conn.execute("SELECT COUNT(*) n FROM installed_apps a JOIN bundles b ON b.id=a.bundle_id "
                              "WHERE b.case_id = ?", (case_id,)).fetchone()["n"]
        return {
            "symptom": c["symptom_text"] if c else None,
            "machine": b["machine_name"] if b else None,
            "collected_utc": b["collected_utc"] if b else None,
            "device_tz": (b["tz_name"] if b else None),
            "events_by_source": by_source,
            "findings": n_find,
            "installed_apps": n_apps,
        }

    def list_findings(_args):
        rows = conn.execute(
            """SELECT f.id, f.severity, f.confidence, f.title, f.rule_id,
                      COUNT(fe.event_id) AS evidence
               FROM findings f LEFT JOIN finding_evidence fe ON fe.finding_id = f.id
               WHERE f.case_id = ? GROUP BY f.id""", (case_id,)).fetchall()
        order = {"critical": 3, "error": 2, "warn": 1, "info": 0}
        rows = sorted(rows, key=lambda r: order.get(r["severity"], 0), reverse=True)
        return [{"id": r["id"], "severity": r["severity"], "confidence": r["confidence"],
                 "title": r["title"], "rule": r["rule_id"], "evidence": r["evidence"]} for r in rows]

    def get_finding(args):
        fid = int(args.get("finding_id"))
        f = conn.execute("SELECT * FROM findings WHERE id = ? AND case_id = ?", (fid, case_id)).fetchone()
        if not f:
            return {"error": f"no finding {fid}"}
        ev = conn.execute(
            """SELECT e.ts_local, e.source, e.event_code, e.actor, e.message
               FROM finding_evidence fe JOIN events e ON e.id = fe.event_id
               WHERE fe.finding_id = ? ORDER BY e.ts_utc LIMIT 8""", (fid,)).fetchall()
        return {"id": f["id"], "title": f["title"], "severity": f["severity"],
                "confidence": f["confidence"], "summary": f["summary"],
                "recommendation": f["recommendation"],
                "evidence": [{"ts": r["ts_local"], "source": r["source"], "code": r["event_code"],
                              "actor": r["actor"], "message": _clip(r["message"])} for r in ev]}

    def search_events(args):
        q = args.get("query", "")
        limit = min(int(args.get("limit", 15)), 40)
        rows = conn.execute(
            """SELECT e.ts_local, e.source, e.severity, e.event_code, e.actor, e.message
               FROM events_fts f JOIN events e ON e.id = f.rowid
               WHERE f.events_fts MATCH ? AND e.case_id = ?
               ORDER BY e.ts_utc LIMIT ?""", (q, case_id, limit)).fetchall()
        return [{"ts": r["ts_local"], "source": r["source"], "severity": r["severity"],
                 "code": r["event_code"], "actor": r["actor"], "message": _clip(r["message"])}
                for r in rows]

    def timeline(args):
        where, params = ["case_id = ?"], [case_id]
        for col, key in (("source", "source"), ("severity", "severity")):
            if args.get(key):
                where.append(f"{col} = ?"); params.append(args[key])
        if args.get("actor"):
            where.append("actor LIKE ?"); params.append(f"{args['actor']}%")
        limit = min(int(args.get("limit", 20)), 50)
        params.append(limit)
        rows = conn.execute(
            f"""SELECT ts_local, source, severity, event_code, actor, message FROM events
                WHERE {' AND '.join(where)} ORDER BY ts_utc IS NULL, ts_utc LIMIT ?""", params).fetchall()
        return [{"ts": r["ts_local"], "source": r["source"], "severity": r["severity"],
                 "code": r["event_code"], "actor": r["actor"], "message": _clip(r["message"])}
                for r in rows]

    def list_apps(args):
        errors_only = bool(args.get("errors_only", True))
        having = "HAVING errors > 0" if errors_only else ""
        rows = conn.execute(
            f"""SELECT e.actor, m.display_name,
                       SUM(e.severity IN ('error','critical')) AS errors,
                       MAX(CASE WHEN e.event_code IS NOT NULL THEN e.event_code END) AS code
                FROM events e LEFT JOIN app_map m ON m.app_guid = e.actor
                WHERE e.case_id = ? AND e.actor IS NOT NULL
                      AND LENGTH(e.actor)=36 AND e.actor LIKE '{guid_like}'
                GROUP BY e.actor {having} ORDER BY errors DESC LIMIT 40""", (case_id,)).fetchall()
        return [{"app_guid": r["actor"], "name": r["display_name"], "errors": r["errors"],
                 "sample_code": r["code"]} for r in rows]

    def inventory(args):
        where, params = ["b.case_id = ?"], [case_id]
        if args.get("contains"):
            where.append("a.display_name LIKE ?"); params.append(f"%{args['contains']}%")
        params.append(min(int(args.get("limit", 30)), 60))
        rows = conn.execute(
            f"""SELECT a.display_name, a.display_version, a.publisher FROM installed_apps a
                JOIN bundles b ON b.id = a.bundle_id WHERE {' AND '.join(where)}
                ORDER BY a.display_name COLLATE NOCASE LIMIT ?""", params).fetchall()
        return [{"name": r["display_name"], "version": r["display_version"],
                 "publisher": r["publisher"]} for r in rows]

    def regquery(args):
        where, params = ["b.case_id = ?", "rv.value_type != 'key'"], [case_id]
        if args.get("key"):
            where.append("rv.key_path LIKE ?"); params.append(f"%{args['key']}%")
        if args.get("name"):
            where.append("rv.value_name LIKE ?"); params.append(f"%{args['name']}%")
        params.append(min(int(args.get("limit", 20)), 40))
        rows = conn.execute(
            f"""SELECT rv.key_path, rv.value_name, rv.value_type, rv.value_data
                FROM registry_values rv JOIN bundles b ON b.id = rv.bundle_id
                WHERE {' AND '.join(where)} ORDER BY rv.key_path LIMIT ?""", params).fetchall()
        return [{"key": r["key_path"], "value": r["value_name"], "type": r["value_type"],
                 "data": _clip(r["value_data"], 80)} for r in rows]

    def detection_for_app(args):
        guid = args.get("app_guid", "")
        vs = detection.verdicts_for(conn, case_id, guid)
        if not vs:
            return {"app_guid": guid, "rules": [],
                    "note": "no cached detection rules (run `rca detection`), or app isn't Win32"}
        return {"app_guid": guid, "rules": [
            {"rule": rule["summary"], "verdict": status, "detail": detail}
            for rule, status, detail in vs]}

    dispatch = {
        "case_overview": case_overview, "list_findings": list_findings, "get_finding": get_finding,
        "search_events": search_events, "timeline": timeline, "list_apps": list_apps,
        "inventory": inventory, "regquery": regquery, "detection_for_app": detection_for_app,
    }
    return _SPECS, dispatch


def _fn(name, description, properties=None, required=None):
    return {"type": "function", "function": {
        "name": name, "description": description,
        "parameters": {"type": "object", "properties": properties or {}, "required": required or []}}}


_SPECS = [
    _fn("case_overview", "Symptom, machine, timezone, event counts by source, and totals. Call this first."),
    _fn("list_findings", "List the rule-engine findings (ranked), each with id, severity, confidence, title."),
    _fn("get_finding", "Full detail + cited evidence events for one finding.",
        {"finding_id": {"type": "integer"}}, ["finding_id"]),
    _fn("search_events", "Full-text search the event timeline (IME/evtx/MSI). Returns matching events.",
        {"query": {"type": "string"}, "limit": {"type": "integer"}}, ["query"]),
    _fn("timeline", "Filtered chronological events.",
        {"source": {"type": "string", "description": "IME|evtx|MSI"},
         "severity": {"type": "string", "description": "info|warn|error|critical"},
         "actor": {"type": "string", "description": "app GUID or provider prefix"},
         "limit": {"type": "integer"}}),
    _fn("list_apps", "Per-app failure rollup from IME (app GUID, resolved name, error count, sample code).",
        {"errors_only": {"type": "boolean"}}),
    _fn("inventory", "Installed apps from the device's Uninstall registry keys.",
        {"contains": {"type": "string"}, "limit": {"type": "integer"}}),
    _fn("regquery", "Query collected registry values (verify detection targets, TLS, posture).",
        {"key": {"type": "string"}, "name": {"type": "string"}, "limit": {"type": "integer"}}),
    _fn("detection_for_app", "For a Win32 app GUID, the fetched detection rules and their verdict on this device.",
        {"app_guid": {"type": "string"}}, ["app_guid"]),
]
