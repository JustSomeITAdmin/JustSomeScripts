"""Configuration-profile state enrichment (Graph).

Pulls the device's per-profile assignment states (deviceConfigurationStates)
so a case shows *profile names + status* next to the device-side PolicyManager
errors — the device logs never carry the Intune profile name/ID. Failing
profiles get their per-setting states too, and any mdm_policy_failures
findings are stamped with the names of error-state profiles (same summary-
append pattern as the detection-rule enrichment; re-running analyze clears it,
re-run this to restore).
"""

from __future__ import annotations

import sqlite3

from rca.enrich import graph
from rca.util import now_utc_iso

_BAD = ("error", "conflict", "nonCompliant")


def fetch_profile_states(conn: sqlite3.Connection, case_id: int,
                         refresh: bool = False, interactive: bool = True) -> dict:
    """Fetch + store profile states for the case's device. Returns a summary."""
    have = conn.execute(
        "SELECT COUNT(*) FROM profile_states WHERE case_id = ?", (case_id,)).fetchone()[0]
    if have and not refresh:
        return _summary(conn, case_id) | {"fetched": 0, "cached": have}

    b = conn.execute(
        "SELECT machine_name FROM bundles WHERE case_id = ? ORDER BY id DESC LIMIT 1",
        (case_id,)).fetchone()
    if not b or not b["machine_name"]:
        return {"error": "no bundle/machine name for this case — ingest first"}
    machine = b["machine_name"]

    token = graph.get_token(interactive=interactive)
    device = graph.get_managed_device(token, machine)
    if not device:
        return {"error": f"no Intune managedDevice named '{machine}' "
                         f"(renamed since collection, or retired?)"}

    states = graph.get_config_states(token, device["id"])
    try:  # Settings Catalog policies live behind a separate beta report
        states += graph.get_settings_catalog_report(token, device["id"])
    except Exception:
        pass  # beta endpoint — classic profiles still stored if it breaks
    now = now_utc_iso()
    conn.execute("DELETE FROM profile_states WHERE case_id = ?", (case_id,))
    seen: set[tuple] = set()  # Graph repeats classic profiles per applied instance
    for s in states:
        key = (s.get("displayName"), s.get("state"), s.get("userPrincipalName"))
        if key in seen:
            continue
        seen.add(key)
        conn.execute(
            """INSERT INTO profile_states
               (case_id, profile_id, display_name, platform_type, state,
                user_principal, fetched_utc)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (case_id, s.get("id"), s.get("displayName"), s.get("platformType"),
             s.get("state"), s.get("userPrincipalName"), now))
        if (s.get("state") in _BAD and s.get("id")
                and s.get("platformType") != "settingsCatalog"):  # no settingStates endpoint for SC
            try:
                settings = graph.get_setting_states(token, device["id"], s["id"])
            except Exception:
                settings = []
            for st in settings:
                if st.get("state") in ("compliant", "notApplicable"):
                    continue
                conn.execute(
                    """INSERT INTO profile_states
                       (case_id, profile_id, display_name, platform_type, state,
                        user_principal, setting_name, setting_state, error_code, fetched_utc)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (case_id, s.get("id"), s.get("displayName"), s.get("platformType"),
                     s.get("state"), st.get("userPrincipalName") or s.get("userPrincipalName"),
                     st.get("settingName"), st.get("state"),
                     str(st.get("errorCode") or "") or None, now))

    _enrich_findings(conn, case_id)
    conn.commit()
    return _summary(conn, case_id) | {"fetched": len(states), "cached": 0}


def _summary(conn, case_id) -> dict:
    rows = conn.execute(
        """SELECT display_name, state FROM profile_states
           WHERE case_id = ? AND setting_name IS NULL""", (case_id,)).fetchall()
    bad = [r["display_name"] for r in rows if r["state"] in _BAD]
    return {"profiles": len(rows), "failing": bad}


def _enrich_findings(conn, case_id) -> None:
    """Stamp error/conflict profile names onto the MDM policy-failure findings."""
    bad = conn.execute(
        """SELECT DISTINCT display_name, state FROM profile_states
           WHERE case_id = ? AND setting_name IS NULL AND state IN (?, ?, ?)""",
        (case_id, *_BAD)).fetchall()
    if not bad:
        return
    names = "; ".join(f"{r['display_name']} ({r['state']})" for r in bad)
    conn.execute(
        """UPDATE findings
           SET summary = summary || ' [Graph] Profiles in a failed/conflict state on this device: ' || ?
           WHERE case_id = ? AND rule_id = 'mdm_policy_failures'
                 AND summary NOT LIKE '%[Graph]%'""",
        (names, case_id))
