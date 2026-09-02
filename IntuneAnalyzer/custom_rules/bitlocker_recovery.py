"""BitLocker recovery-mode root cause, classified by event fingerprint.

Recovery = BitLocker-Driver 24635 (PCR mismatch) / 24636 / 24652 (recovery
password used). What changed the measurements is decided by an evidence
hierarchy, NOT by whichever Intune script last mentioned Secure Boot (that
mis-blamed a 6-day-old CA report in the field):

  secureboot_db  24658 at the recovery boot ("Secure Boot configuration
                 changed"), or TPM-WMI 1808 (device updated Secure Boot
                 CA/keys) in the 72h before it.
  firmware       flash-driver service (SCM 7045 DBUtilDrv2 etc.) or 'Dell
                 Firmware Update' log in the 72h before.
  tpm_clear      TPM cleared/reset in the 72h before.
  bootmgr_swap   BitLocker-API 881 (OS Loader Authority not in the boot
                 manager's verified chain) around the recovery, usually with
                 a CU restart (MoUsoCoreWorker/TrustedInstaller) as the last
                 thing before the machine went down: the 2023-CA-signed boot
                 manager was staged and PCR 7 was never re-sealed.
  unknown        none of the above.

Also reports whether a BitLocker suspend (API 773) preceded the change, the
last shutdown before the recovery boot (initiator + gap), BIOS date, and the
813/1032 secondary signals.
"""

import re
import zipfile
from datetime import datetime, timedelta

from rca.ruleset import Finding, rule

_FLASH_SVC = ("dbutil", "biosflash", "firmwareupdate", "flashsvc")
_CU_INITIATORS = ("mousocoreworker", "trustedinstaller", "usoclient")


def _dt(v):
    if not v:
        return None
    try:
        return datetime.fromisoformat(v.replace("Z", "+00:00"))
    except ValueError:
        return None


def _bios_date(conn, case_id):
    """BIOS flash date from msinfo32.log in the package ('4/30/2026'), or None."""
    row = conn.execute(
        "SELECT source_path FROM bundles WHERE case_id = ? LIMIT 1", (case_id,)).fetchone()
    if not row:
        return None
    try:
        with zipfile.ZipFile(row["source_path"]) as z:
            member = next((i for i in z.infolist()
                           if i.filename.lower().endswith("msinfo32.log") and i.file_size > 0), None)
            if not member:
                return None
            # ponytail: 6MB UTF-16 file, field is in the first few KB
            head = z.open(member).read(16384).decode("utf-16", "replace")
        m = re.search(r"BIOS Version/Date\t(.+)", head)
        return m.group(1).strip() if m else None
    except Exception:
        return None


def _q(conn, case_id, where, params=()):
    return conn.execute(
        f"""SELECT id, ts_local, ts_utc, actor, event_code, message FROM events
            WHERE case_id = ? AND source = 'evtx' AND {where} ORDER BY ts_utc""",
        (case_id, *params)).fetchall()


@rule
def rule_bitlocker_recovery(conn, case_id):
    recovery = _q(conn, case_id,
                  "actor LIKE '%BitLocker%' AND event_code IN ('24635','24636','24652','24658')")
    if not recovery:
        return []
    t0 = _dt(recovery[0]["ts_utc"])
    if t0 is None:
        return []
    pre = (t0 - timedelta(hours=72)).isoformat()
    post = (t0 + timedelta(minutes=30)).isoformat()
    t0s = t0.isoformat()

    used = any(r["event_code"] == "24652" for r in recovery)
    pcr = any(r["event_code"] == "24635" for r in recovery)
    sb_changed = [r for r in recovery if r["event_code"] == "24658"]

    def window(where, lo, hi, params=()):
        return _q(conn, case_id, f"({where}) AND ts_utc BETWEEN ? AND ?", (*params, lo, hi))

    ca_updated = window("actor LIKE '%TPM-WMI%' AND event_code = '1808'", pre, t0s)
    flash = [r for r in window("event_code = '7045' OR actor = 'Dell Firmware Update'", pre, t0s)
             if r["actor"] == "Dell Firmware Update"
             or any(k in r["message"].lower() for k in _FLASH_SVC)]
    tpm_clear = window("(actor LIKE '%TPM%') AND (lower(message) LIKE '%tpm%clear%' "
                       "OR lower(message) LIKE '%tpm%reset%')", pre, t0s)
    authority = window("actor LIKE '%BitLocker-API%' AND event_code = '881'",
                       (t0 - timedelta(hours=1)).isoformat(), post)
    suspended = window("actor LIKE '%BitLocker-API%' AND event_code = '773'", pre, t0s)
    n813 = conn.execute(
        """SELECT COUNT(*) FROM events WHERE case_id = ? AND source = 'evtx'
           AND event_code = '813' AND actor LIKE '%BitLocker%'""", (case_id,)).fetchone()[0]
    n1032 = conn.execute(
        """SELECT COUNT(*) FROM events WHERE case_id = ? AND source = 'evtx'
           AND event_code LIKE '%1032' AND actor LIKE '%TPM-WMI%'""", (case_id,)).fetchone()[0]

    # Last session before the recovery boot: shutdown time + restart initiator.
    last_down = conn.execute(
        """SELECT ts_local, ts_utc FROM events WHERE case_id = ? AND source = 'evtx'
           AND actor LIKE '%Kernel-General%' AND event_code = '13' AND ts_utc < ?
           ORDER BY ts_utc DESC LIMIT 1""", (case_id, t0s)).fetchone()
    last_1074 = conn.execute(
        """SELECT ts_local, message FROM events WHERE case_id = ? AND source = 'evtx'
           AND event_code = '1074' AND ts_utc < ? ORDER BY ts_utc DESC LIMIT 1""",
        (case_id, t0s)).fetchone()
    initiator = ""
    if last_1074:
        m = re.search(r"The process (\S+)", last_1074["message"])
        initiator = m.group(1).split("\\")[-1] if m else ""
    cu_restart = any(k in initiator.lower() for k in _CU_INITIATORS)
    gap = ""
    if last_down and _dt(last_down["ts_utc"]):
        hrs = (t0 - _dt(last_down["ts_utc"])).total_seconds() / 3600
        gap = (f" Last shutdown {last_down['ts_local'][:19]}"
               + (f" (restart initiated by {initiator})" if initiator else "")
               + f", {hrs:.1f}h before the recovery boot.")

    # ---- classification (explicit event beats inference) ----
    if sb_changed or ca_updated:
        cls, conf = "secureboot_db", "high"
        cause = ("Secure Boot DB/CA changed: "
                 + ("Bootmgr reported 'Secure Boot configuration changed' (24658)"
                    if sb_changed else
                    f"TPM-WMI 1808 'device updated Secure Boot CA/keys' at "
                    f"{ca_updated[-1]['ts_local'][:19]}")
                 + " — the DB update rewrote PCR 7 while the TPM protector was active.")
        rec = ("Fleet: whatever applies the Secure Boot CA/DB update must "
               "`Suspend-BitLocker -MountPoint C: -RebootCount 1` first (the suspend guard "
               "covers this only when it sees the update pending before the reboot).")
    elif flash:
        cls, conf = "firmware", "high"
        cause = (f"Firmware flash re-measured the platform: {flash[0]['actor']} / "
                 f"{flash[0]['message'][:60].strip()} at {flash[0]['ts_local'][:19]} "
                 f"(BIOS/TPM firmware update before the recovery boot).")
        rec = ("Firmware updaters must suspend BitLocker before staging the capsule; "
               "find what delivered the flash (DCU, PMPC app, remediation) and gate it.")
    elif tpm_clear:
        cls, conf = "tpm_clear", "high"
        cause = f"TPM was cleared/reset at {tpm_clear[-1]['ts_local'][:19]} — all sealed keys invalidated."
        rec = ("Expect Windows Hello/NGC keys to be gone too (re-provision PIN). "
               "Identify who cleared the TPM (firmware update, tpm.msc, Clear-Tpm).")
    elif authority:
        cls, conf = "bootmgr_swap", "high"
        cause = ("Boot manager signing authority changed: BitLocker-API 881 'OS Loader "
                 "Authority not in the boot manager's verified certificate chain' — the "
                 "Windows UEFI CA 2023-signed boot manager was staged"
                 + (f" by a Windows Update servicing restart ({initiator})" if cu_restart else "")
                 + " and PCR 7 was never re-sealed before the first boot with it.")
        rec = ("This trigger is invisible to Secure-Boot-pending checks (no DB change). "
               "Mitigation is on the servicing side: let CU restarts complete (a machine "
               "powered off mid-restart boots into recovery later), and consider "
               "`Suspend-BitLocker -RebootCount 1` in the CU maintenance window on fleets "
               "still on the 2011-signed boot manager. Recovery key entry reseals it.")
    elif (ca_after := window("actor LIKE '%TPM-WMI%' AND event_code = '1808'", t0s, post)):
        # The CA/DB update logs 1808 on the boot AFTER it was applied; when the
        # System log starts at the recovery boot (short retention) this is the
        # only trace of it (seen in the field).
        cls, conf = "secureboot_db", "medium"
        mins = int((_dt(ca_after[0]["ts_utc"]) - t0).total_seconds() // 60)
        cause = (f"Secure Boot DB/CA change (probable): TPM-WMI 1808 'device updated Secure "
                 f"Boot CA/keys' logged {mins} min AFTER the recovery boot and nothing earlier "
                 f"in the collected log — the update was applied around the preceding "
                 f"shutdown and rewrote PCR 7 while the TPM protector was active.")
        rec = ("Same fleet fix as a confirmed DB change: suspend BitLocker before the CA/DB "
               "update. Collect sooner next time so the boot before the trip is in the log.")
    else:
        cls, conf = "unknown", "medium"
        cause = ("No Secure Boot DB change, firmware flash, TPM clear, or boot-manager "
                 "authority change found in the package.")
        rec = "Check firmware/BIOS history on the device and the boot before the recovery."

    if cls != "unknown":
        cause += (f" A BitLocker suspend (773) WAS logged at {suspended[-1]['ts_local'][:19]} "
                  f"but did not cover this boot." if suspended
                  else " No BitLocker suspend (773) preceded the change.")
    bios = _bios_date(conn, case_id)
    if bios:
        cause += f" BIOS version/date on device: {bios}."

    what = "recovery password required at boot" if used else "TPM key release failed at boot"
    label = {"secureboot_db": "Secure Boot DB/CA change", "firmware": "firmware flash",
             "tpm_clear": "TPM clear", "bootmgr_swap": "boot-manager swap (2023 CA)",
             "unknown": "trigger not identified"}[cls]
    return [Finding(
        rule_id="bitlocker_recovery",
        title=f"BitLocker entered recovery — {label}",
        severity="error", confidence=conf,
        summary=(f"BitLocker {what}{' (PCR mismatch)' if pcr else ''} at "
                 f"{recovery[0]['ts_local'][:19]}. {cause}{gap}"
                 + (f" BitLocker-API 813 (Secure Boot integrity unusable) logged {n813}x." if n813 else "")
                 + (f" TPM-WMI 1032 logged {n1032}x (Windows deferring Secure Boot variable "
                    f"updates because they'd trip BitLocker — KB5016061)." if n1032 else "")),
        recommendation="One-time: enter the recovery key; BitLocker reseals automatically. " + rec,
        evidence_event_ids=[r["id"] for r in recovery]
                           + [r["id"] for r in (ca_updated[-1:] + flash[:1] + tpm_clear[-1:]
                                                 + authority[:1] + suspended[-1:])])]
