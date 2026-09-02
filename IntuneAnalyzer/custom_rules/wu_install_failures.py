"""Windows Update install failures, named by KB.

Source: Microsoft-Windows-WindowsUpdateClient event 20 —
"Installation Failure: Windows failed to install the following update with
error 0xXXXXXXXX: <title>." Parses on plain `parse` (evtx), no ETL decode
needed, and names the exact update — the signal that drowns in the WU trace's
benign error chatter (0x80248007/0x80070032/...).
"""

import re

from rca import errormap
from rca.ruleset import Finding, rule

_M = re.compile(r"error (0x[0-9A-Fa-f]{8}):\s*(.+?)\.?\s*$", re.S)


@rule
def rule_wu_install_failures(conn, case_id):
    rows = conn.execute(
        """SELECT id, ts_utc, message FROM events
           WHERE case_id = ? AND source = 'evtx'
             AND actor LIKE '%WindowsUpdateClient%' AND event_code LIKE '%/20'
             AND message LIKE '%Installation Failure%'
           ORDER BY ts_utc""", (case_id,)).fetchall()
    # event_code may be stored as 'Provider/20' or plain '20'
    if not rows:
        rows = conn.execute(
            """SELECT id, ts_utc, message FROM events
               WHERE case_id = ? AND source = 'evtx'
                 AND message LIKE '%Installation Failure: Windows failed to install%'
               ORDER BY ts_utc""", (case_id,)).fetchall()
    if not rows:
        return []

    groups: dict[tuple, dict] = {}
    for r in rows:
        m = _M.search(r["message"])
        if not m:
            continue
        code, title = "0x" + m.group(1)[2:].upper(), m.group(2).strip()[:120]
        g = groups.setdefault((title, code), {"n": 0, "ids": [], "last": ""})
        g["n"] += 1
        g["ids"].append(r["id"])
        g["last"] = r["ts_utc"] or g["last"]

    findings = []
    for (title, code), g in groups.items():
        info = errormap.lookup(code) or {}
        meaning = info.get("label", "")
        rec = info.get("recommendation") or (
            "Look up the code, then check the WU timeline (source=WU) around the "
            "last attempt for the component-level failure.")
        sev = "error" if "security update" in title.lower() or "cumulative" in title.lower() \
              else "warn"
        findings.append(Finding(
            rule_id="wu_install_failures",
            title=f"Update failing: {title} ({code}, {g['n']}x)",
            severity=sev, confidence="high",
            summary=(f"Windows Update failed to install '{title}' {g['n']} time(s), "
                     f"last at {g['last'][:16]}, with {code}"
                     + (f" — {meaning}." if meaning else ".")),
            recommendation=rec,
            evidence_event_ids=g["ids"][:10]))
    return findings
