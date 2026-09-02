"""Detect 'IME can't get a token' cluster — usually a stale/missing AAD session.

Be careful with dsregcmd output here: Intune's "Collect diagnostics" runs
dsregcmd as SYSTEM (Executing Account Name = COMPUTERNAME$), where the
user-context fields (AzureAdPrt, IsUserAzureAD) are *always* NO regardless of
whether the interactive user has a PRT. Only trust those fields when the
collection ran as an interactive user — otherwise this rule only flags the
IME token-failure cluster and leaves the user-session question open.
"""

import zipfile

from rca.ruleset import Finding, rule


def _dsregcmd_user_context(conn, case_id) -> bool:
    """True only if dsregcmd was run as an interactive user (not SYSTEM)."""
    row = conn.execute(
        """SELECT a.rel_path, b.source_path FROM artifacts a
           JOIN bundles b ON b.id = a.bundle_id
           WHERE b.case_id = ? AND lower(a.rel_path) LIKE '%dsregcmd%' LIMIT 1""",
        (case_id,)).fetchone()
    if not row:
        return False
    try:
        with zipfile.ZipFile(row["source_path"]) as z:
            txt = z.read(row["rel_path"]).decode("utf-8", "replace")
    except Exception:
        return False
    # SYSTEM/computer account shows e.g. "Executing Account Name : WORKGROUP\HOSTNAME$"
    for ln in txt.splitlines():
        if "Executing Account Name" in ln and ln.rstrip().endswith("$"):
            return False
    return True


@rule
def rule_ime_token_failures(conn, case_id):
    rows = conn.execute(
        """SELECT id FROM events
           WHERE case_id = ? AND source = 'IME'
             AND (message LIKE '%TokenAquireException%'
                  OR message LIKE '%AAD User check%is failed%')
           ORDER BY ts_utc""", (case_id,)).fetchall()
    if len(rows) < 3:  # a cluster, not a one-off
        return []

    user_ctx = _dsregcmd_user_context(conn, case_id)
    note = (" dsregcmd was collected as an interactive user; if AzureAdPrt is NO "
            "there it's authoritative." if user_ctx else
            " (dsregcmd here was collected from SYSTEM, so its AzureAdPrt/IsUserAzureAD "
            "fields are not meaningful for the interactive user.)")

    return [Finding(
        rule_id="ime_token_failures",
        title=f"IME token-acquisition failing ({len(rows)} times)",
        severity="warn", confidence="medium",
        summary=f"IME logged TokenAquireException / failed AAD User check {len(rows)} "
                f"time(s). The interactive user's AAD session (PRT) may be stale.{note}",
        recommendation=(
            "Have the user run `dsregcmd /status` from THEIR own command prompt "
            "(not elevated) — check AzureAdPrt=YES, IsUserAzureAD=YES, and that "
            "WamDefaultSet is not 0x80070520. If any of those are wrong, signing out "
            "and signing back in with the AAD/Entra account usually restores them."),
        evidence_event_ids=[r["id"] for r in rows[:10]])]


@rule
def rule_no_required_apps(conn, case_id):
    """If IME tracks only Available (Intent=3) apps, 'nothing happens after enrollment'
    is expected — Available apps don't auto-install. Likely an assignment-scope issue.

    Defers to the ESP user-sync wedge rule: if user-sync is incomplete, the small
    app count is a *symptom* of the wedge, not an assignment-scope problem.
    """
    wedge = conn.execute(
        """SELECT 1 FROM events WHERE case_id = ? AND source = 'IME'
           AND message LIKE '%IsSyncDoneForUser: False%' LIMIT 1""", (case_id,)).fetchone()
    if wedge:
        return []  # the wedge rule will surface the real cause
    rows = conn.execute(
        """SELECT actor, message FROM events
           WHERE case_id = ? AND source = 'IME' AND message LIKE '%ReportingState%'""",
        (case_id,)).fetchall()
    if not rows:
        return []
    import re
    seen, required, available = set(), 0, 0
    for r in rows:
        if r["actor"] in seen:
            continue
        seen.add(r["actor"])
        m = re.search(r'"Intent":\s*(\d+)', r["message"])
        if not m:
            continue
        intent = int(m.group(1))
        if intent == 4:
            required += 1
        elif intent in (1, 3, 6):
            available += 1
    if required > 0 or available < 3:
        return []
    sample_ids = list(seen)[:8]
    return [Finding(
        rule_id="no_required_apps",
        title=f"No Required apps assigned ({available} Available-only)",
        severity="warn", confidence="medium",
        summary=(f"IME knows about {available} app(s), all with Intent=Available — "
                 "user-pulled, not auto-install. There are 0 Required-intent apps in "
                 "policy. If you expected apps to install automatically after "
                 "enrollment, the assignment scope likely doesn't include this device "
                 "or user (group membership, dynamic-group evaluation, or assignment "
                 "intent set to Available instead of Required)."),
        recommendation=(
            "1) In Intune, open Apps > By Platform > Windows, filter to apps with "
            "Required assignments, and confirm this device's groups are in the "
            "include list (and not in the exclude list). 2) For dynamic groups, "
            "verify the device satisfies the rule — fresh devices can take time. "
            "3) Run `rca resolve -c {0}` to see what 5 apps the device IS seeing "
            "and compare against what should be there."
        ).format(case_id),
        evidence_event_ids=[])]
