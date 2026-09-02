"""Unattended vendor BIOS/firmware flash (the "who rebooted my lab machine" case).

Field case (a lab desktop, Aug 2026): PatchMyPC delivered Dell Command Update;
a fresh DCU install resets its schedule to defaults, and before the nightly
schedule-disable remediation could run, DCU scanned, staged a BIOS capsule and
rebooted the machine itself. Users report it as "the firmware updater ran out
of nowhere" / "a normal reboot" — the 1074 initiator is wmiprvse, not the user.
On machines with NI PCIe cards the capsule hangs at 0% until power-cycled.

Fingerprint (all within minutes, System log):
  1. SCM 7045: a flash kernel driver service installed (Dell's DBUtilDrv2;
     match generic BIOS/flash driver names too)
  2. BitLocker-API 773: BitLocker suspended (capsule staging always does this)
  3. User32 1074 initiated by wmiprvse.exe: the tool's scripted auto-reboot

Fires on 1+2 (error/high); the reboot and any "Dell Firmware Update" classic
log events are pulled in as supporting evidence when present.
"""

from datetime import datetime, timedelta

from rca.ruleset import Finding, rule

_FLASH_SVC = ("dbutil", "biosflash", "firmwareupdate", "flashsvc")


def _ts(row):
    v = row["ts_utc"] or row["ts_local"] or ""
    try:
        return datetime.fromisoformat(v.replace("Z", "+00:00").replace("z", "+00:00"))
    except ValueError:
        return None


@rule
def rule_unattended_bios_flash(conn, case_id):
    svc_rows = [
        r for r in conn.execute(
            """SELECT id, ts_local, ts_utc, message FROM events
               WHERE case_id = ? AND event_code = '7045'
               ORDER BY ts_utc""", (case_id,)).fetchall()
        if any(k in r["message"].lower() for k in _FLASH_SVC)
    ]
    if not svc_rows:
        return []

    suspends = conn.execute(
        """SELECT id, ts_local, ts_utc FROM events
           WHERE case_id = ? AND event_code = '773'
             AND message LIKE '%BitLocker was suspended%' ORDER BY ts_utc""",
        (case_id,)).fetchall()
    reboots = conn.execute(
        """SELECT id, ts_local, ts_utc FROM events
           WHERE case_id = ? AND event_code = '1074'
             AND message LIKE '%wmiprvse%' ORDER BY ts_utc""",
        (case_id,)).fetchall()
    dell_log = conn.execute(
        """SELECT id FROM events
           WHERE case_id = ? AND actor = 'Dell Firmware Update' LIMIT 4""",
        (case_id,)).fetchall()

    findings = []
    for svc in svc_rows:
        t0 = _ts(svc)
        if t0 is None:
            continue
        near_suspend = [s for s in suspends
                        if (ts := _ts(s)) and abs(ts - t0) <= timedelta(minutes=10)]
        if not near_suspend:
            continue
        near_reboot = [b for b in reboots
                       if (ts := _ts(b)) and timedelta(0) <= ts - t0 <= timedelta(minutes=15)]
        when = svc["ts_local"][:19] if svc["ts_local"] else "?"
        findings.append(Finding(
            rule_id="unattended_bios_flash",
            title=f"Unattended BIOS/firmware flash staged at {when[11:16]}",
            severity="error", confidence="high",
            summary=(
                f"A firmware-flash driver service was installed at {when} (SCM 7045), "
                f"BitLocker was suspended within minutes (capsule staging)"
                + (f", and a scripted wmiprvse restart followed at "
                   f"{near_reboot[0]['ts_local'][11:19]} — the flash tool rebooted the "
                   f"machine itself; this is NOT a user reboot." if near_reboot else ".")
                + (" 'Dell Firmware Update' classic-log events confirm a Dell flash "
                   "utility." if dell_log else "")),
            recommendation=(
                "Identify what delivered/triggered the flash tool: check Uninstall-key "
                "install_date for Dell Command Update / vendor updaters (a fresh install "
                "resets schedules to defaults and races any schedule-disable "
                "remediation), and recent app assignments (PatchMyPC). If this device "
                "class must not receive BIOS (e.g. NI PCIe cards hang the capsule at "
                "0%), exclude the group from the updater app, or configure the updater "
                "to exclude BIOS/firmware (dcu-cli /configure -updateType="
                "driver,application). A machine dark for a long stretch after the "
                "restart = the capsule hung; power-cycle recovers it, and BitLocker "
                "resumes with a fresh TPM seal on the next boot."),
            evidence_event_ids=([svc["id"]] + [s["id"] for s in near_suspend]
                                + [b["id"] for b in near_reboot[:2]]
                                + [d["id"] for d in dell_log]),
        ))
    return findings
