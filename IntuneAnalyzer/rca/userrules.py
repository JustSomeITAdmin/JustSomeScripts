"""No-code (declarative) rules stored in the user_rules table.

These let a tech author rules from the web UI without Python or SQL: pick a
source / event code / message substring / severity, and a finding is emitted
when matching events meet a minimum count. Cross-source correlation still
belongs in Python rules (rca/rules.py + custom_rules/); this covers the common
"flag when code X / text Y shows up" case.

Each row is compiled into the same (conn, case_id) -> [Finding] callable shape
the engine already runs, so declarative and Python rules are treated uniformly.
"""

from __future__ import annotations

import sqlite3

from rca import errormap
from rca.ruleset import Finding


def _safe_format(template: str, **kw) -> str:
    """Format a user template, tolerating typo'd {placeholders}."""
    try:
        return template.format(**kw)
    except (KeyError, ValueError, IndexError):
        return template


def _compile(spec: sqlite3.Row):
    rule_id = f"user:{spec['id']}"
    name = spec["name"]

    def rule_fn(conn: sqlite3.Connection, case_id: int) -> list[Finding]:
        where = ["case_id = ?"]
        params: list = [case_id]
        if spec["match_source"]:
            where.append("source = ?"); params.append(spec["match_source"])
        if spec["match_code"]:
            where.append("event_code = ?"); params.append(spec["match_code"])
        if spec["match_severity"]:
            where.append("severity = ?"); params.append(spec["match_severity"])
        if spec["match_contains"]:
            where.append("message LIKE ?"); params.append(f"%{spec['match_contains']}%")
        rows = conn.execute(
            f"""SELECT id, actor, event_code FROM events
                WHERE {' AND '.join(where)}""", params).fetchall()
        if not rows:
            return []

        # Default recommendation: the rule's text, else the error_map meaning.
        rec = spec["recommendation"] or ""
        if not rec and spec["match_code"]:
            info = errormap.lookup(spec["match_code"])
            if info:
                rec = info.get("recommendation", "")
        rec = rec or "Review the matching events in the timeline."

        groups: dict = {}
        if spec["group_by_actor"]:
            for r in rows:
                groups.setdefault(r["actor"], []).append(r)
        else:
            groups[None] = rows

        findings: list[Finding] = []
        for actor, evs in groups.items():
            if len(evs) < (spec["min_count"] or 1):
                continue
            code = next((e["event_code"] for e in evs if e["event_code"]), spec["match_code"] or "")
            title = _safe_format(spec["title"], count=len(evs),
                                 actor=actor or "(various)", code=code or "")
            summary = (f"Rule '{name}' matched {len(evs)} event(s)"
                       + (f" for {actor}" if actor else "")
                       + (f" with code {code}" if code else "") + ".")
            findings.append(Finding(
                rule_id=rule_id, title=title, severity=spec["severity"],
                confidence=spec["confidence"], summary=summary, recommendation=rec,
                evidence_event_ids=[e["id"] for e in evs]))
        return findings

    rule_fn.__name__ = f"userrule_{spec['id']}"
    return rule_fn


def load_user_rule_callables(conn: sqlite3.Connection) -> list[tuple]:
    """Return [(callable, 'user-rule'), ...] for every enabled declarative rule."""
    rows = conn.execute("SELECT * FROM user_rules WHERE enabled = 1 ORDER BY id").fetchall()
    return [(_compile(r), "user-rule") for r in rows]
