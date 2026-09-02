"""Third-party installer initiated a restart (the Autopilot/ESP flow-breaker).

User32/1074 names every restart's initiating process. OS-owned restarts
(winlogon, CloudExperienceHost, shutdown.exe scheduled tasks, USO, deviceenroller)
are normal; a restart initiated by an installer binary under Program Files /
Temp / staging paths is the classic silent Autopilot breaker — it bypasses
IME's DeviceRestartBehavior entirely because the installer calls the shutdown
API itself (field case: CrowdStrike FalconSensor_Windows.exe rebooting
mid-Windows-Hello-enrollment; also any MSI/EXE lacking /norestart).

Requires the System log parsed at info level (evtx parser does this for the
System channel automatically).
"""

import re

from rca.ruleset import Finding, rule

# OS-initiated restart processes we consider normal.
_OS_OK = re.compile(
    r"\\Windows\\(System32|SysWOW64)\\(winlogon|shutdown|svchost|CloudExperienceHostBroker"
    r"|MusNotification|wuauclt|deviceenroller|wininit|RuntimeBroker)\.exe",
    re.I)
_PROC = re.compile(r"The process (.+?\.exe)", re.I)


@rule
def rule_installer_forced_restart(conn, case_id):
    rows = conn.execute(
        """SELECT id, ts_local, message FROM events
           WHERE case_id = ? AND event_code LIKE '%1074'
             AND message LIKE '%initiated the restart%'
           ORDER BY ts_utc""", (case_id,)).fetchall()
    findings = []
    for r in rows:
        m = _PROC.search(r["message"])
        if not m:
            continue
        proc = m.group(1)
        if _OS_OK.search(proc):
            continue
        # wmiprvse = WMI-driven (scheduled task / Restart-Computer) - name it
        # but classify separately from an app installer.
        is_wmi = "wmiprvse" in proc.lower()
        exe = proc.split("\\")[-1]
        findings.append(Finding(
            rule_id="installer_forced_restart",
            title=(f"Restart initiated by {'WMI/script' if is_wmi else 'installer'}: "
                   f"{exe} at {r['ts_local'][11:16]}"),
            severity="warn", confidence="high",
            summary=(f"User32/1074 at {r['ts_local'][:19]}: {proc} initiated a restart. "
                     f"{'A scheduled task or Restart-Computer call.' if is_wmi else 'An installer calling the shutdown API directly bypasses IME DeviceRestartBehavior - during Autopilot/ESP this breaks the enrollment flow (e.g. at the Hello screen).'}"),
            recommendation=(
                "Identify which package spawned this process (path often names it). "
                "For installers: add the vendor's no-restart switch (/norestart or "
                "equivalent) to the install command - IME-side restart settings "
                "cannot stop an installer that reboots directly. For WMI/script "
                "initiators: check scheduled tasks and remediation scripts."),
            evidence_event_ids=[r["id"]]))
    return findings
