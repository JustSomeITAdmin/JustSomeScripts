"""Fetch Win32 app detection rules from Graph and evaluate them against the
device data we already parsed (registry_values / installed_apps).

What's provable from a diagnostics package:
  * MSI **product-code** detection - we have the Uninstall keys, so present/absent
    is definitive.
  * **registry** detection - only if that key was in Intune's collected set;
    otherwise we report 'unknown' (can't confirm from this package).
  * **file** / **script** detection - shown but not evaluable offline.

Rules are cached per app (app_detection); the device verdict is computed live so
it reflects whichever case/machine you're looking at.
"""

from __future__ import annotations

import json
import sqlite3

from rca.enrich import graph, resolver
from rca.util import now_utc_iso

# --- normalize Graph's two rule shapes (legacy detectionRules + unified rules) ---

def _odata_kind(odata: str) -> str | None:
    o = (odata or "").lower()
    if "productcode" in o:
        return "productcode"
    if "registry" in o:
        return "registry"
    if "filesystem" in o:
        return "file"
    if "powershellscript" in o:
        return "script"
    return None


def _summary(rule: dict) -> str:
    k = rule["kind"]
    if k == "productcode":
        v = f" {rule.get('productVersionOperator','')} {rule.get('productVersion','')}".rstrip()
        return f"MSI product code {rule.get('productCode','?')}{v if v.strip() else ''}"
    if k == "registry":
        vn = rule.get("valueName") or "(default)"
        op = rule.get("operator") or ""
        dv = rule.get("detectionValue")
        tail = f" {rule.get('detectionType','')} {op} {dv}".rstrip() if dv is not None else \
               f" {rule.get('detectionType','exists')}"
        w = " [32-bit view]" if rule.get("check32") else ""
        return f"registry {rule.get('keyPath','?')}\\{vn}{tail}{w}"
    if k == "file":
        return f"file {rule.get('path','?')}\\{rule.get('fileOrFolderName','?')} " \
               f"{rule.get('detectionType','exists')}"
    if k == "script":
        return "PowerShell detection script"
    return "unknown rule"


def normalize_rules(app_json: dict) -> list[dict]:
    """Return a list of normalized detection rules from a mobileApp object."""
    out: list[dict] = []

    def add(odata, src, ruletype_ok=True):
        kind = _odata_kind(odata)
        if not kind or not ruletype_ok:
            return
        r = {"kind": kind}
        if kind == "productcode":
            r.update(productCode=src.get("productCode"),
                     productVersion=src.get("productVersion"),
                     productVersionOperator=src.get("productVersionOperator"))
        elif kind == "registry":
            r.update(keyPath=src.get("keyPath"), valueName=src.get("valueName"),
                     detectionType=src.get("detectionType") or src.get("operationType"),
                     operator=src.get("operator"),
                     detectionValue=src.get("detectionValue") or src.get("comparisonValue"),
                     check32=src.get("check32BitOn64System"))
        elif kind == "file":
            r.update(path=src.get("path"), fileOrFolderName=src.get("fileOrFolderName"),
                     detectionType=src.get("detectionType") or src.get("operationType"),
                     operator=src.get("operator"),
                     detectionValue=src.get("detectionValue") or src.get("comparisonValue"),
                     check32=src.get("check32BitOn64System"))
        r["summary"] = _summary(r)
        out.append(r)

    for src in app_json.get("detectionRules") or []:
        add(src.get("@odata.type"), src)
    if not out:  # fall back to the unified rules collection, detection only
        for src in app_json.get("rules") or []:
            add(src.get("@odata.type"), src, ruletype_ok=(src.get("ruleType") == "detection"))
    return out


# --- evaluation against the device's collected data ---------------------------

def _norm_key(k: str | None) -> str:
    k = (k or "").strip().strip("\\").lower()
    return k.replace("hkey_local_machine", "hklm").replace("hkey_current_user", "hkcu")


def _eval_productcode(conn, case_id, rule) -> tuple[str, str]:
    pc = (rule.get("productCode") or "").strip().lower()
    if not pc:
        return "unknown", "no product code on rule"
    variants = {pc, pc.strip("{}"), "{" + pc.strip("{}") + "}"}
    rows = conn.execute(
        """SELECT ia.key_name, ia.display_name, ia.display_version
           FROM installed_apps ia JOIN bundles b ON b.id = ia.bundle_id
           WHERE b.case_id = ?""", (case_id,)).fetchall()
    for r in rows:
        if (r["key_name"] or "").lower() in variants:
            return "satisfied", (f"product registered: {r['display_name']} "
                                 f"{r['display_version'] or ''}".strip())
    return "not_satisfied", "MSI product code not found in the device's installed apps"


def _eval_registry(conn, case_id, rule) -> tuple[str, str]:
    target = _norm_key(rule.get("keyPath"))
    vname = rule.get("valueName")
    if vname:
        rows = conn.execute(
            """SELECT rv.key_path, rv.value_type, rv.value_data FROM registry_values rv
               JOIN bundles b ON b.id = rv.bundle_id
               WHERE b.case_id = ? AND rv.value_name = ? COLLATE NOCASE""",
            (case_id, vname)).fetchall()
    else:
        rows = conn.execute(
            """SELECT rv.key_path, rv.value_type, NULL AS value_data FROM registry_values rv
               JOIN bundles b ON b.id = rv.bundle_id
               WHERE b.case_id = ? AND rv.value_name IS NULL""", (case_id,)).fetchall()
    matches = [r for r in rows if _norm_key(r["key_path"]) == target]
    if not matches:
        return "unknown", ("registry key/value not in the collected diagnostics - "
                           "run `rca collect-script` to gather it from the device")

    # An 'absent'/'key-absent' row means a supplemental script explicitly checked.
    present_rows = [m for m in matches if (m["value_type"] or "") not in ("absent", "key-absent")]
    present = bool(present_rows)
    dtype = (rule.get("detectionType") or "exists").lower()

    if dtype in ("exists", "notconfigured", ""):
        return ("satisfied", "value present on device") if present else \
               ("not_satisfied", "value absent on device (checked)")
    if dtype == "doesnotexist":
        return ("not_satisfied", "value present, but rule requires absence") if present else \
               ("satisfied", "value absent, as required")
    if not present:
        return "not_satisfied", "value absent on device (checked) - can't satisfy a value match"
    data, dval, op = present_rows[0]["value_data"], rule.get("detectionValue"), rule.get("operator")
    ok = _compare(data, op, dval, dtype)
    return ("satisfied" if ok else "not_satisfied"), f"device value '{data}' {op} '{dval}'"


def _eval_file(conn, case_id, rule) -> tuple[str, str]:
    path = (rule.get("path") or "").rstrip("\\")
    name = rule.get("fileOrFolderName") or ""
    full = (path + "\\" + name) if name else path
    # case-insensitive full-path match against collected file facts
    fmatch = None
    for r in conn.execute(
        """SELECT ff.path, ff.present, ff.version FROM file_facts ff
           JOIN bundles b ON b.id = ff.bundle_id WHERE b.case_id = ?""", (case_id,)).fetchall():
        if (r["path"] or "").lower() == full.lower():
            fmatch = r
            break
    if fmatch is None:
        return "unknown", ("file not in the collected diagnostics - "
                           "run `rca collect-script` to check it on the device")
    present = bool(fmatch["present"])
    dtype = (rule.get("detectionType") or "exists").lower()
    if dtype in ("exists", "notconfigured", ""):
        return ("satisfied", "file present") if present else ("not_satisfied", "file absent (checked)")
    if dtype == "doesnotexist":
        return ("not_satisfied", "file present, but rule requires absence") if present else \
               ("satisfied", "file absent, as required")
    if dtype == "version" and present:
        ok = _compare(fmatch["version"], rule.get("operator"), rule.get("detectionValue"), "version")
        return ("satisfied" if ok else "not_satisfied"), \
               f"file version '{fmatch['version']}' {rule.get('operator')} '{rule.get('detectionValue')}'"
    return ("unknown", "file present; rule attribute not evaluable offline") if present else \
           ("not_satisfied", "file absent (checked)")


def _compare(data, op, expected, dtype) -> bool:
    if data is None or expected is None:
        return False
    try:
        if dtype == "version":
            a = tuple(int(x) for x in str(data).split("."))
            b = tuple(int(x) for x in str(expected).split("."))
        elif dtype == "integer":
            a, b = int(data), int(expected)
        else:
            a, b = str(data), str(expected)
    except ValueError:
        a, b = str(data), str(expected)
    return {
        "equal": a == b, "notEqual": a != b,
        "greaterThan": a > b, "greaterThanOrEqual": a >= b,
        "lessThan": a < b, "lessThanOrEqual": a <= b,
    }.get(op, a == b)


def evaluate_rule(conn, case_id, rule) -> tuple[str, str]:
    """Return (status, detail). status: satisfied | not_satisfied | unknown."""
    kind = rule["kind"]
    if kind == "productcode":
        return _eval_productcode(conn, case_id, rule)
    if kind == "registry":
        return _eval_registry(conn, case_id, rule)
    if kind == "file":
        return _eval_file(conn, case_id, rule)
    if kind == "script":
        return "unknown", "script detection - can't evaluate offline; see IME script-exit events"
    return "unknown", "unrecognized rule type"


# --- fetch + cache ------------------------------------------------------------

def fetch_case(conn: sqlite3.Connection, case_id: int, errors_only: bool = True,
               force: bool = False, interactive: bool = True,
               device_code_prompt=print, progress_cb=None) -> dict:
    guids = resolver.case_app_guids(conn, case_id, errors_only=errors_only)
    if not guids:
        return {"total": 0, "fetched": 0, "cached": 0, "not_found": 0, "errors": 0}
    cached = {r["app_guid"] for r in conn.execute("SELECT app_guid FROM app_detection")}
    todo = guids if force else [g for g in guids if g not in cached]
    summary = {"total": len(guids), "fetched": 0,
               "cached": len(guids) - len(todo), "not_found": 0, "errors": 0}
    if not todo:
        return summary

    token = graph.get_token(interactive=interactive, device_code_prompt=device_code_prompt)
    for i, g in enumerate(todo, 1):
        try:
            app = graph.get_app_raw(token, g)
        except Exception:
            summary["errors"] += 1
            continue
        if app is None:
            summary["not_found"] += 1
        else:
            rules = normalize_rules(app)
            conn.execute(
                """INSERT INTO app_detection (app_guid, app_odata_type, rules_json, fetched_utc)
                   VALUES (?, ?, ?, ?)
                   ON CONFLICT(app_guid) DO UPDATE SET
                     app_odata_type=excluded.app_odata_type, rules_json=excluded.rules_json,
                     fetched_utc=excluded.fetched_utc""",
                (g, app.get("@odata.type"), json.dumps(rules), now_utc_iso()),
            )
            summary["fetched"] += 1
        if progress_cb:
            progress_cb(i, len(todo))
    conn.commit()
    return summary


def verdicts_for(conn, case_id, guid) -> list[tuple[dict, str, str]]:
    """Return [(rule, status, detail)] for a cached app, evaluated for this case."""
    row = conn.execute("SELECT rules_json FROM app_detection WHERE app_guid = ?", (guid,)).fetchone()
    if not row or not row["rules_json"]:
        return []
    out = []
    for rule in json.loads(row["rules_json"]):
        status, detail = evaluate_rule(conn, case_id, rule)
        out.append((rule, status, detail))
    return out


def finding_note(conn, case_id, guid) -> str | None:
    """One-line detection summary for enriching a finding (offline; uses cache)."""
    vs = verdicts_for(conn, case_id, guid)
    if not vs:
        return None
    parts = []
    for rule, status, detail in vs:
        parts.append(f"detection rule '{rule['summary']}' -> {status} ({detail})")
    return " | ".join(parts)
