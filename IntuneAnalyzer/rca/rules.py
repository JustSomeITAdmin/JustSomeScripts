"""Built-in rule pack: deterministic, explainable RCA rules.

Each rule is decorated with @rule (auto-registered — no array to maintain) and
returns Findings that link to the events proving them. Rules target known-
meaningful signals, not log noise, and never hallucinate. Error-code meanings
come from the editable errormap, not hard-coded here.

To add your own, drop a *.py into custom_rules/ (see custom_rules/README.md).
"""

from __future__ import annotations

import sqlite3

from rca import errormap
from rca.enrich import detection
from rca.ruleset import Finding, rule

_DEFAULT_CODE = {"label": "Win32 app failure", "confidence": "medium",
                 "recommendation": "Review the app's install/detection/requirement "
                 "configuration and the IME AppWorkload log around these events."}


def _app_name(conn: sqlite3.Connection, guid: str) -> str:
    row = conn.execute("SELECT display_name FROM app_map WHERE app_guid = ?", (guid,)).fetchone()
    if row and row["display_name"]:
        return row["display_name"]
    return guid


@rule
def rule_win32_app_failures(conn: sqlite3.Connection, case_id: int) -> list[Finding]:
    """IME-reported Win32 app failures, one finding per (app, code), code-aware."""
    rows = conn.execute(
        """SELECT id, actor, event_code, ts_local, ts_utc FROM events
           WHERE case_id = ? AND source = 'IME' AND actor IS NOT NULL
                 AND severity IN ('error','critical')
                 AND event_code LIKE '0x%' AND event_code != '0x00000000'
                 -- IME service start replays each app's cached prior state
                 -- ("...loaded and reporting state initialized"); counting those
                 -- as fresh failures made stale codes look live (field case).
                 AND message NOT LIKE '%reporting state initialized%'""",
        (case_id,),
    ).fetchall()

    groups: dict[tuple[str, str], list] = {}
    for r in rows:
        groups.setdefault((r["actor"], r["event_code"]), []).append(r)

    findings = []
    for (guid, code), evs in groups.items():
        info = errormap.lookup(code) or _DEFAULT_CODE
        label, conf, rec = info["label"], info["confidence"], info["recommendation"]
        name = _app_name(conn, guid)
        latest = max((e["ts_local"] or e["ts_utc"] or "") for e in evs)
        summary = (f"App '{name}' ({guid}) reported '{label}' [{code}] "
                   f"{len(evs)} time(s); latest {latest}.")
        # If detection rules were fetched (`rca detection`), prove/locate the cause.
        note = detection.finding_note(conn, case_id, guid)
        if note:
            summary += f" {note}."
        elif code == "0x87D1041C":
            summary += (" Run `rca detection -c {0}` to fetch the detection rule and "
                        "check it against this device.".format(case_id))
        findings.append(Finding(
            rule_id="win32_app_failure",
            title=f"{name}: {label} ({code})",
            severity="error", confidence=conf,
            summary=summary, recommendation=rec,
            evidence_event_ids=[e["id"] for e in evs],
        ))
    return findings


@rule
def rule_msi_install_failures(conn: sqlite3.Connection, case_id: int) -> list[Finding]:
    """MSI logs whose final result code is a failure."""
    rows = conn.execute(
        """SELECT id, actor, event_code, ts_local, ts_utc FROM events
           WHERE case_id = ? AND source = 'MSI' AND severity = 'error'
                 AND message LIKE 'Installation result:%'""",
        (case_id,),
    ).fetchall()
    findings = []
    for r in rows:
        findings.append(Finding(
            rule_id="msi_install_failure",
            title=f"{r['actor']}: MSI install failed (code {r['event_code']})",
            severity="error", confidence="high",
            summary=f"Windows Installer returned {r['event_code']} for '{r['actor']}' "
                    f"at {r['ts_local'] or r['ts_utc']}.",
            recommendation="Open the app's .msi.log around this result; look upward for the "
                           "first 'Return value 3' or failed custom action to find the failing "
                           "action. 1603=generic fatal, 1618=another install in progress, "
                           "1638=already installed.",
            evidence_event_ids=[r["id"]],
        ))
    return findings


@rule
def rule_script_nonzero_exit(conn: sqlite3.Connection, case_id: int) -> list[Finding]:
    """Detection/remediation PowerShell scripts that exited non-zero."""
    rows = conn.execute(
        """SELECT id, message, ts_local, ts_utc FROM events
           WHERE case_id = ? AND source = 'IME'
                 AND event_code LIKE 'exit=%' AND event_code != 'exit=0'""",
        (case_id,),
    ).fetchall()
    if not rows:
        return []
    return [Finding(
        rule_id="script_nonzero_exit",
        title=f"Detection/remediation script(s) exited non-zero ({len(rows)})",
        severity="warn", confidence="medium",
        summary="One or more IME-run scripts returned a non-zero exit code. "
                f"Example: {rows[0]['message'][:160]}",
        recommendation="A non-zero exit from a detection script means 'not detected'; from a "
                       "remediation/requirement script it can block install. Run the script "
                       "manually on a like device to reproduce.",
        evidence_event_ids=[r["id"] for r in rows],
    )]


@rule
def rule_appx_deployment_errors(conn: sqlite3.Connection, case_id: int) -> list[Finding]:
    """AppX deployment failures in the event log (can block Store/MSIX apps)."""
    rows = conn.execute(
        """SELECT id FROM events
           WHERE case_id = ? AND source = 'evtx' AND severity IN ('error','critical')
                 AND actor = 'Microsoft-Windows-AppXDeployment-Server'""",
        (case_id,),
    ).fetchall()
    if not rows:
        return []
    return [Finding(
        rule_id="appx_deployment_errors",
        title=f"AppX/MSIX deployment errors in event log ({len(rows)})",
        severity="warn", confidence="medium",
        summary=f"{len(rows)} AppXDeployment-Server error events. These often accompany "
                "failed Store/MSIX app provisioning or removal.",
        recommendation="Correlate timestamps with the Win32/MSIX app failures above; check "
                       "the AppXDeploymentServer/Operational log for the specific package.",
        evidence_event_ids=[r["id"] for r in rows[:25]],
    )]


@rule
def rule_device_collection_failures(conn: sqlite3.Connection, case_id: int) -> list[Finding]:
    """Diagnostics items the device failed to collect (context, not root cause)."""
    rows = conn.execute(
        """SELECT a.rel_path, a.collection_hresult FROM artifacts a
           JOIN bundles b ON b.id = a.bundle_id
           WHERE b.case_id = ? AND a.collection_status = 'error'""",
        (case_id,),
    ).fetchall()
    if not rows:
        return []
    sample = ", ".join(r["rel_path"].split("] ", 1)[-1][:40] for r in rows[:4])
    return [Finding(
        rule_id="device_collection_failures",
        title=f"{len(rows)} diagnostics items failed to collect on the device",
        severity="info", confidence="high",
        summary=f"Some collection targets weren't present/readable (e.g. {sample}). "
                "Usually benign (feature not installed), but a missing expected log can "
                "explain gaps in this analysis.",
        recommendation="See `rca artifacts -c {0} --status error`. Investigate only if a log "
                       "you need for this case is among them.".format(case_id),
        evidence_event_ids=[],
    )]
