"""Configuration-profile (MDM policy CSP) merge failures.

Source: DeviceManagement-Enterprise-Diagnostics-Provider Admin log (inside the
mdmlogs CAB — parsed since the mdm-evtx routing fix). Event 821 is the money
line: "Merge of policy did not complete successfully, Policy: (X), Area: (Y),
Result:(0xXXXXXXXX) <plain-English meaning>." — one finding per failing area.
"""

import re

from rca.ruleset import Finding, rule

_M = re.compile(r"Policy:\s*\(([^)]*)\).*?Area:\s*\(([^)]*)\).*?"
                r"Result:\s*\((0x[0-9A-Fa-f]+)\)\s*(.*?)\.*$", re.S)


@rule
def rule_mdm_policy_failures(conn, case_id):
    rows = conn.execute(
        """SELECT id, ts_utc, message FROM events
           WHERE case_id = ? AND source = 'evtx' AND event_code = '821'
             AND severity IN ('error', 'critical')
           ORDER BY ts_utc""", (case_id,)).fetchall()
    if not rows:
        return []

    # Group by (area, result-code); event text sometimes swaps Policy/Area, so
    # normalize: the CSP area is whichever of the two isn't a generic verb.
    groups: dict[tuple, dict] = {}
    for r in rows:
        m = _M.search(r["message"])
        if not m:
            continue
        a, b, code, meaning = m.group(1), m.group(2), m.group(3).upper(), m.group(4).strip()
        area = b if a in ("Configure", "Merge", "Set") else a
        g = groups.setdefault((area, code), {"n": 0, "ids": [], "meaning": meaning})
        g["n"] += 1
        g["ids"].append(r["id"])

    findings = []
    for (area, code), g in groups.items():
        rec = ("Fix the profile itself — the device never applied it (PolicyManager\\"
               "current stays empty until the merge succeeds). ")
        if "no mapping between account names" in g["meaning"].lower():
            rec += ("0x80070534 on a group/user policy means an account in the profile "
                    "can't be resolved to a SID. Entra ID groups must be referenced by "
                    "SID (S-1-12-1-..., derived from the group objectId), not display "
                    "name; names only work for local or AD-synced accounts.")
        elif "unable to parse" in g["meaning"].lower():
            rec += ("0x800705B9 means the policy XML is malformed — validate it "
                    "(smart quotes from copy/paste, unclosed tags, and stray BOMs are "
                    "the usual culprits).")
        else:
            rec += "Check the code's meaning and the profile's payload for this CSP area."
        findings.append(Finding(
            rule_id="mdm_policy_failures",
            title=f"Configuration profile failing: {area} ({code}, {g['n']}x)",
            severity="error", confidence="high",
            summary=(f"MDM PolicyManager rejected the {area} policy {g['n']} time(s) "
                     f"with {code}: {g['meaning']}"),
            recommendation=rec,
            evidence_event_ids=g["ids"][:10]))
    return findings
