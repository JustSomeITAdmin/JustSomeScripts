"""Windows Hello for Business policy tombstones (retired profile still enforcing).

Unassigning a WHfB/PassportForWork profile does NOT remove its CSP values —
they persist in HKLM\\SOFTWARE\\Microsoft\\Policies\\PassportForWork\\<tenant>
and Windows keeps enforcing them (PIN expiry being the classic: users hit
"PIN expired" months after the profile was retired, each when their PIN age
crosses the tombstoned threshold).

Fires when:
  - a nonzero PINComplexity Expiration value is in the registry (definitive;
    captured by Collect-IntuneDiag.ps1's PassportForWork export), or
  - PassportForWork resources are still enrolled per MDMDiagReport.xml AND the
    case symptom mentions PIN/Hello/WHfB (symptom-gated to avoid firing on
    every machine that legitimately runs Hello).
"""

import re
import zipfile
from pathlib import Path

from rca.ruleset import Finding, rule


def _diag_report_text(conn, case_id):
    row = conn.execute(
        """SELECT a.rel_path, a.raw_path, a.materialized, b.source_path
           FROM artifacts a JOIN bundles b ON b.id = a.bundle_id
           WHERE b.case_id = ? AND lower(a.rel_path) LIKE '%mdmdiagreport.xml' LIMIT 1""",
        (case_id,)).fetchone()
    if not row:
        return ""
    try:
        if row["materialized"] and row["raw_path"] and Path(row["raw_path"]).exists():
            raw = Path(row["raw_path"]).read_bytes()
        else:
            with zipfile.ZipFile(row["source_path"]) as z:
                raw = z.read(row["rel_path"])
        return raw.decode("utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8",
                          "replace")
    except Exception:
        return ""


@rule
def rule_whfb_tombstone(conn, case_id):
    # Definitive: an actual Expiration value in the PassportForWork policy store.
    exp = conn.execute(
        """SELECT rv.key_path, rv.value_data FROM registry_values rv
           JOIN bundles b ON b.id = rv.bundle_id
           WHERE b.case_id = ? AND lower(rv.key_path) LIKE '%policies%passportforwork%'
                 AND lower(rv.value_name) = 'expiration'""", (case_id,)).fetchall()
    exp_days = None
    for r in exp:
        try:
            v = int(str(r["value_data"]), 0)
        except (TypeError, ValueError):
            continue
        if v > 0:
            exp_days = v
            break

    # Supporting: PassportForWork still an enrolled MDM resource.
    resources = re.findall(r"<ResourceName>([^<]*PassportForWork[^<]*)</ResourceName>",
                           _diag_report_text(conn, case_id))

    symptom = (conn.execute("SELECT symptom_text FROM cases WHERE id = ?",
                            (case_id,)).fetchone()["symptom_text"] or "").lower()
    symptom_gate = any(k in symptom for k in ("pin", "hello", "whfb", "passport"))

    if exp_days is None and not (resources and symptom_gate):
        return []

    if exp_days is not None:
        headline = f"WHfB PIN expiration tombstone active ({exp_days} days)"
        detail = (f"The PassportForWork policy store carries Expiration={exp_days} — "
                  f"Windows enforces PIN expiry from this value regardless of current "
                  f"Intune assignments.")
        conf = "high"
    else:
        headline = "WHfB policy enrolled (check: intended, or tombstoned leftover?)"
        detail = (f"{len(resources)} PassportForWork resource(s) enrolled per "
                  f"MDMDiagReport. If Hello is INTENDED for this device class (e.g. "
                  f"group-tag targeting), this is informational. If not, remember: "
                  f"unassigning a WHfB profile does not remove its CSP values — a "
                  f"retired PIN-expiry setting keeps enforcing.")
        conf = "low"

    return [Finding(
        rule_id="whfb_tombstone",
        title=headline,
        severity="warn", confidence=conf,
        summary=(f"{detail} Symptom pattern: users hit 'PIN expired' when their PIN age "
                 f"crosses the tombstoned threshold — a rolling wave across every machine "
                 f"that ever received the old profile."),
        recommendation=(
            "Confirm on-device: reg query \"HKLM\\SOFTWARE\\Microsoft\\Policies\\"
            "PassportForWork\" /s /f Expiration. Fix by OVERWRITING, not deleting: "
            "assign a WHfB configuration with PIN expiration = 0 (never) to the affected "
            "population; once applied everywhere it can be safely retired (a 'never' "
            "tombstone is harmless). Census the fleet with a detection-only Proactive "
            "Remediation that flags nonzero Expiration values."),
        evidence_event_ids=[])]
