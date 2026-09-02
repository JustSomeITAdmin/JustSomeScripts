"""Run the rule pack over a case and persist findings + evidence."""

from __future__ import annotations

import sqlite3

from rca.ruleset import load_rules
from rca.userrules import load_user_rule_callables
from rca.util import now_utc_iso


def analyze_case(conn: sqlite3.Connection, case_id: int) -> dict:
    """Re-run all rules for a case. Replaces prior findings. Returns counts."""
    conn.execute("DELETE FROM findings WHERE case_id = ?", (case_id,))  # cascades evidence
    n_findings = n_evidence = 0

    # Built-in + custom Python rules, then no-code rules from the user_rules table.
    rules = load_rules() + load_user_rule_callables(conn)
    errors: list[str] = []
    for rule_fn, _source in rules:
        try:
            produced = list(rule_fn(conn, case_id))
        except Exception as exc:  # one bad rule shouldn't sink the whole run
            errors.append(f"{rule_fn.__name__}: {type(exc).__name__}: {exc}")
            continue
        for f in produced:
            cur = conn.execute(
                """INSERT INTO findings
                   (case_id, rule_id, title, confidence, severity, summary,
                    recommendation, created_utc)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (case_id, f.rule_id, f.title, f.confidence, f.severity,
                 f.summary, f.recommendation, now_utc_iso()),
            )
            fid = cur.lastrowid
            for eid in f.evidence_event_ids[:50]:
                conn.execute(
                    "INSERT OR IGNORE INTO finding_evidence (finding_id, event_id) VALUES (?, ?)",
                    (fid, eid),
                )
                n_evidence += 1
            n_findings += 1

    conn.execute("UPDATE cases SET status = 'analyzed' WHERE id = ?", (case_id,))
    conn.commit()
    return {"findings": n_findings, "evidence": n_evidence, "errors": errors}
