"""Detect 'wedged in ESP user-sync' — device delivers only initial app set; reboot resolves.

After enrollment, IME's V3Processor pulls Win32 app policy on a recurring
schedule (hourly by default). When the device is gated on the ESP user phase
('IsSyncDoneForUser: False' with no user SID recorded under
SOFTWARE\\Microsoft\\Enrollments\\<id>\\FirstSync), the processor can pin to a
small subset of subgraphs — usually just the initial device-context apps — and
never advance to the full Required-app set even when Intune has many more
assigned. The Win32AppInventory thread also skips ('no any AAD User logged in').

Symptom: 'I enrolled, nothing installs, but a reboot makes it start.' Reboot
restarts IME and re-evaluates the FirstSync state machine.

Detection: same low subgraph count across many consecutive check-ins + the
'IsSyncDoneForUser: False' / 'no any AAD User logged in' markers.
"""

from rca.ruleset import Finding, rule


@rule
def rule_esp_user_sync_wedge(conn, case_id):
    # 1) How many distinct subgraph counts has V3Processor been processing?
    rows = conn.execute(
        """SELECT id, ts_utc, message FROM events
           WHERE case_id = ? AND source = 'IME'
             AND message LIKE '%[Win32App][V3Processor]%Processing % subgraphs%'
           ORDER BY ts_utc""", (case_id,)).fetchall()
    if len(rows) < 4:
        return []

    import re
    counts = []
    for r in rows:
        m = re.search(r"Processing (\d+) subgraphs", r["message"])
        if m:
            counts.append((r["id"], r["ts_utc"], int(m.group(1))))
    if len(counts) < 4:
        return []

    last_n = counts[-1][2]
    distinct = {c for _, _, c in counts}
    plateau = sum(1 for _, _, c in counts if c == last_n)
    if plateau < 4 or last_n > 30:  # be conservative — only fire on small, persistent counts
        return []

    # 2) Corroborating markers for the user-sync wedge.
    user_sync_false = conn.execute(
        """SELECT COUNT(*) FROM events WHERE case_id = ? AND source = 'IME'
           AND message LIKE '%IsSyncDoneForUser: False%'""", (case_id,)).fetchone()[0]
    no_user = conn.execute(
        """SELECT COUNT(*) FROM events WHERE case_id = ? AND source = 'IME'
           AND message LIKE '%no any AAD User logged in%'""", (case_id,)).fetchone()[0]
    if not (user_sync_false or no_user):
        return []   # the pattern's headline is the user-sync gate; don't fire without it

    # 3) Cycle span gives us a meaningful "hours wedged" number.
    from datetime import datetime
    def _parse(ts):
        try: return datetime.fromisoformat(ts.rstrip("Z").split(".")[0])
        except Exception: return None
    a, b = _parse(counts[0][1]), _parse(counts[-1][1])
    hours = round((b - a).total_seconds() / 3600, 1) if a and b else None
    span = f" over ~{hours}h" if hours else ""

    return [Finding(
        rule_id="esp_user_sync_wedge",
        title=f"Win32 policy wedged at {last_n} subgraphs{span} — likely ESP user-sync gate",
        severity="error", confidence="high",
        summary=(
            f"V3Processor ran {len(counts)} check-in cycle(s) and always returned the "
            f"same {last_n} subgraph(s) — no growth toward the assignments Intune is "
            f"showing. Corroborating IME markers: IsSyncDoneForUser=False ({user_sync_false}x), "
            f"'no any AAD User logged in' inventory skips ({no_user}x). The device hasn't "
            f"completed its user-context first sync, so Required apps beyond the initial "
            f"set are not being pulled — even when policy in Intune has many more assigned."),
        recommendation=(
            "Reboot the device. This is the documented escape: IME restarts with a fresh "
            "in-memory policy graph, ESP re-evaluates FirstSync, and the user logon event "
            "after reboot writes the user SID under SOFTWARE\\Microsoft\\Enrollments\\<id>\\"
            "FirstSync. If a reboot doesn't help, force a sync from Settings > Accounts > "
            "Access work or school, and check that the user signing in is the targeted "
            "AAD user (not a local account). Persistent occurrences across many devices "
            "suggest reviewing the ESP profile (skipUserStatusPage) and any user-targeted "
            "app dependencies that may be blocking the device-context graph."),
        evidence_event_ids=[i for i, _, _ in counts[:10]])]
