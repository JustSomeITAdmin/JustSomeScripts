"""TPM refusing key templates / losing key objects — the Windows Hello death precursor.

TPM/17 ("hardware failed to execute a TPM command") is mostly noise: TPM2_Sign
(ordinal 349) returning RC_SIZE shows up by the thousand on healthy machines.
Two combinations are NOT noise — field-proven on the only two devices in the
fleet that lost their Hello container (both Nuvoton 2.0 fw 7.2.x), and absent
on every device that kept it:

  ordinal 394 = TPM2_TestParms   -> response 452 = RC_VALUE   (TPM rejects a key/
                                    algorithm template during Windows provisioning)
  ordinal 371 = TPM2_ReadPublic  -> response 395 = RC_HANDLE  (a key object the OS
                                    expects no longer exists in the TPM)

On those machines the container failed to load (HelloForBusiness 7002
0xD0000225) after a servicing reboot that re-ran TPM provisioning. Requires the
evtx worker to append EventData to TPM messages (read_evtx.ps1 does).
"""

import re

from rca.ruleset import Finding, events_of, rule

_ORD = re.compile(r"TpmCommandOrdinal=(\d+); TpmResponseCode=(\d+)")
_BAD = {("394", "452"): "TPM2_TestParms -> RC_VALUE (key template rejected)",
        ("371", "395"): "TPM2_ReadPublic -> RC_HANDLE (key object missing)"}


@rule
def rule_tpm_key_failures(conn, case_id):
    hits, ids, first, last = {}, [], None, None
    for r in events_of(conn, case_id, "TPM", "17"):
        m = _ORD.search(r["message"] or "")
        if not m or (m.group(1), m.group(2)) not in _BAD:
            continue
        hits[(m.group(1), m.group(2))] = hits.get((m.group(1), m.group(2)), 0) + 1
        ids.append(r["id"])
        first = first or r["ts_local"]
        last = r["ts_local"]
    if not hits:
        return []

    dead = events_of(conn, case_id, "HelloForBusiness", "7002")
    tpm = conn.execute(
        """SELECT message FROM events WHERE case_id = ? AND source = 'evtx'
           AND actor LIKE '%HelloForBusiness%' AND event_code = '5000'
           ORDER BY ts_utc DESC LIMIT 1""", (case_id,)).fetchone()
    tpm_id = ""
    if tpm:
        g = re.search(r"TPM Manufacturer: (.+?) Version: ([\d.]+) Firmware Version: ([\d.]+)",
                      " ".join(tpm["message"].split()))
        if g:
            tpm_id = f" TPM: {g.group(1)} {g.group(2)} fw {g.group(3)}."

    detail = "; ".join(f"{_BAD[k]} x{n}" for k, n in hits.items())
    return [Finding(
        rule_id="tpm_key_failures",
        title=("TPM key-object failures — Hello container already dead" if dead
               else "TPM key-object failures — Windows Hello at risk"),
        severity="error" if dead else "warn", confidence="high",
        summary=(f"TPM/17 with the Hello-death fingerprint: {detail} "
                 f"({first[:19]} .. {last[:19]}).{tpm_id} "
                 + (f"HelloForBusiness 7002 (container failed to load) logged {len(dead)}x — "
                    f"the container was invalidated across a TPM provisioning run."
                    if dead else
                    "No container-load failure yet; on affected devices the loss followed "
                    "the next servicing reboot that re-ran TPM provisioning.")),
        recommendation=(
            "Treat the TPM as faulty, not the user: apply the vendor TPM firmware update "
            "(separate from BIOS); if the fingerprint persists, clear the TPM (suspend "
            "BitLocker first, recovery key escrowed) and re-enroll Hello; still "
            "persisting = replace the board/TPM. If Hello is already dead: "
            "`certutil -DeleteHelloContainer` as the user, sign out, password sign-in, set "
            "the PIN (re-enrolls in ~30 s). Fleet: a detection-only remediation that "
            "counts TPM/17 with ordinal 394/response 452 or 371/395 finds the next one "
            "before its PIN dies."),
        evidence_event_ids=ids[:20] + [d["id"] for d in dead[:3]])]
