"""LocalUsersAndGroups destructive replace on BUILTIN\\Users (the ESP killer).

Field case (two freshly enrolled classroom machines, Aug 2026): a LUG policy with
`<group action="R"/>` on `desc="S-1-5-32-545"` strips NT AUTHORITY\\
Authenticated Users and INTERACTIVE from BUILTIN\\Users — deliberately, as
access control (allowed users regain Users transitively via the Entra group
SIDs listed as members). Fatal only when it lands DURING OOBE/ESP: defaultuser0
belongs to no Entra group, so after the next reboot its auto-logon token has no
Users membership and Winlogon loops 6004 "<Profiles> failed a critical
notification event" every ~2 minutes; users see "User Profile Service failed
the sign-in". The strip happens even when the merge then errors, and is not
rolled back.

Second signature: the CSP merge ABORTS at the first name it cannot resolve
(0x80070534 ERROR_NONE_MAPPED) and silently never processes any member listed
after it — Microsoft's docs claim invalid members are skipped; they are wrong.
So order members SIDs first, names last.
"""

import re

from rca.ruleset import Finding, rule

_ACCESSGROUP = re.compile(
    r'<accessgroup\s+desc="S-1-5-32-545">(.*?)</accessgroup>', re.S | re.I)
_MEMBER = re.compile(r'<add\s+member="([^"]+)"', re.I)


@rule
def rule_lug_destructive_replace(conn, case_id):
    rows = conn.execute(
        """SELECT id, ts_utc, message FROM events
           WHERE case_id = ? AND message LIKE '%LocalUsersAndGroups%'
             AND message LIKE '%S-1-5-32-545%' AND message LIKE '%action="R"%'
           ORDER BY ts_utc""", (case_id,)).fetchall()
    replace_evt = None
    members = []
    for r in rows:
        m = _ACCESSGROUP.search(r["message"])
        if m and 'action="R"' in m.group(1):
            replace_evt = r
            members = _MEMBER.findall(m.group(1))
            break
    if not replace_evt:
        return []

    findings = []
    names = [x for x in members if not x.upper().startswith("S-1-")]

    # Signature 1: the replace collided with enrollment — Winlogon <Profiles>
    # death loop present in the same case.
    profs = conn.execute(
        """SELECT id FROM events
           WHERE case_id = ? AND event_code = '6004'
             AND message LIKE '%<Profiles>%' ORDER BY ts_utc""",
        (case_id,)).fetchall()
    if profs:
        findings.append(Finding(
            rule_id="lug_destructive_replace",
            title=("LUG replace on BUILTIN\\Users landed during enrollment — "
                   "profile sign-in death loop"),
            severity="error", confidence="high",
            summary=(f"A LocalUsersAndGroups policy with action=\"R\" on "
                     f"BUILTIN\\Users (S-1-5-32-545) applied while the device was "
                     f"still in OOBE/ESP, stripping Authenticated Users/INTERACTIVE. "
                     f"defaultuser0's auto-logon then fails every ~2 min "
                     f"(Winlogon 6004 '<Profiles>' x{len(profs)}); interactive users "
                     f"get 'User Profile Service failed the sign-in'. ESP never "
                     f"completes."),
            recommendation=(
                "Do NOT add S-1-5-11/S-1-5-4 back to the policy — the strip IS the "
                "access control (logon restricted to the member Entra groups). The "
                "fix is timing: keep new devices OUT of the policy's targeting group "
                "until the build completes (e.g. a static group you add devices to only "
                "after imaging). Recover a wedged machine with the built-in "
                "Administrator (whatever your rename policy calls it) + LAPS password, then "
                "`net localgroup Users \"NT AUTHORITY\\Authenticated Users\" /add`, "
                "let OOBE/ESP finish — the policy's next Replace merge strips it "
                "back out automatically."),
            evidence_event_ids=[replace_evt["id"]] + [p["id"] for p in profs[:5]]))

    # Signature 2: merge aborted at an unresolvable NAME — everything after it
    # in the member list was silently never applied.
    if names:
        nm = conn.execute(
            """SELECT id FROM events
               WHERE case_id = ? AND message LIKE '%LocalUsersAndGroups%'
                 AND message LIKE '%0x80070534%' ORDER BY ts_utc LIMIT 1""",
            (case_id,)).fetchone()
        if nm:
            findings.append(Finding(
                rule_id="lug_destructive_replace",
                title=("LUG merge aborted at an unresolvable name — later members "
                       "silently skipped"),
                severity="warn", confidence="high",
                summary=(f"The LocalUsersAndGroups merge failed with 0x80070534 "
                         f"(no name-to-SID mapping) on one of the by-name members "
                         f"({', '.join(names)}). The CSP aborts at the first failed "
                         f"name and never processes members listed after it (docs "
                         f"claim they're skipped individually; they are not). The "
                         f"destructive group replace still happened and is not "
                         f"rolled back."),
                recommendation=(
                    "Order members SIDs first, local-account names last, so an "
                    "unprovisioned local account can't take the rest of the list "
                    "down. Then fix why the account is missing (typically the script "
                    "that is supposed to create your local lab/offline accounts)."),
                evidence_event_ids=[replace_evt["id"], nm["id"]]))
    return findings
