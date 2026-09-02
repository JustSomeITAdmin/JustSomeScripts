"""Nightly scheduled restart colliding with the Windows Update install window.

Update rings with AllowAutoUpdate=2 and no explicit ScheduledInstallTime run
the WU install pass at the 03:00 default. An admin reboot task scheduled at/
near 03:00 guillotines it nightly: updates stage, never commit, and wedge
'in-use sandbox' (WU_E_OPERATIONINPROGRESS on every retry). Fleet symptom:
some machines quietly stop taking cumulatives while everything else works.

Detection: repeated shutdown signals in the 03:00 window across several days
+ wedged-sandbox / OPERATIONINPROGRESS evidence in the WU log.
"""

import collections

from rca.ruleset import Finding, rule


@rule
def rule_wu_reboot_collision(conn, case_id):
    # Nightly shutdowns inside the default WU install window (03:00-03:10).
    rows = conn.execute(
        """SELECT id, ts_local FROM events
           WHERE case_id = ? AND source = 'IME'
             AND message LIKE '%received shutdown signal%'
             AND substr(ts_local, 12, 5) >= '02:55' AND substr(ts_local, 12, 5) <= '03:10'
           ORDER BY ts_utc""", (case_id,)).fetchall()
    days = collections.Counter(r["ts_local"][:10] for r in rows)
    if len(days) < 3:
        return []

    wedged = conn.execute(
        """SELECT id FROM events WHERE case_id = ? AND source = 'WU'
           AND (message LIKE '%in-use sandbox%' OR message LIKE '%80240009%')
           ORDER BY ts_utc LIMIT 10""", (case_id,)).fetchall()

    sev = "error" if wedged else "warn"
    conf = "high" if wedged else "medium"
    wedge_note = (f" {len(wedged)}+ WU log lines show updates wedged 'in-use sandbox' / "
                  f"WU_E_OPERATIONINPROGRESS — staged installs that never commit." if wedged
                  else " No wedged-update evidence yet, but the collision window exists.")
    return [Finding(
        rule_id="wu_reboot_collision",
        title=f"Scheduled restart collides with WU install window ({len(days)} nights at ~03:00)",
        severity=sev, confidence=conf,
        summary=(f"The device restarts inside 02:55-03:10 on {len(days)} distinct day(s) — "
                 f"the default Windows Update scheduled-install slot (AllowAutoUpdate=2 with "
                 f"no ScheduledInstallTime = 03:00). WU starts its install pass and the "
                 f"restart kills it seconds later, nightly.{wedge_note}"),
        recommendation=(
            "Move the nightly reboot task/profile out of 02:30-05:00 (e.g. 00:30, with any "
            "cleanup task chained after it), or set an explicit scheduled install time in "
            "the update ring. If updates are already wedged: stop wuauserv+bits, delete "
            "SoftwareDistribution\\Download, restart services, re-scan. Verify the restart "
            "initiators with System event 1074 (names the process and task)."),
        evidence_event_ids=[r["id"] for r in rows[:8]] + [w["id"] for w in wedged[:2]])]
