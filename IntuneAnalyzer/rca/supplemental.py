"""Supplemental collection: fill gaps the Intune package can't, so custom-key
detection rules become evaluable.

Flow:
  1. `rca collect-script` reads the cached detection rules for a case's failing
     apps and generates a targeted PowerShell collector for exactly the registry
     values / files those rules check.
  2. The tech runs it on the affected device; it writes a JSON file.
  3. `rca supplemental` ingests that JSON into a per-case 'supplemental' bundle:
     registry -> registry_values (with explicit 'absent' rows), files -> file_facts.

Then `rca detection` / `rca analyze` evaluate against it — a missing key becomes
a definitive 'not_satisfied' instead of 'unknown'.
"""

from __future__ import annotations

import json
import sqlite3

from rca.enrich import resolver
from rca.util import now_utc_iso

SCHEMA = "rca-supplemental/1"


def collect_targets(conn: sqlite3.Connection, case_id: int, errors_only: bool = True) -> dict:
    """Gather registry/file targets from cached detection rules of failing apps."""
    guids = resolver.case_app_guids(conn, case_id, errors_only=errors_only)
    regs: dict[tuple, dict] = {}
    files: dict[tuple, dict] = {}
    for g in guids:
        row = conn.execute("SELECT rules_json FROM app_detection WHERE app_guid = ?", (g,)).fetchone()
        if not row or not row["rules_json"]:
            continue
        for rule in json.loads(row["rules_json"]):
            if rule["kind"] == "registry":
                key = (rule.get("keyPath"), rule.get("valueName"))
                regs[key] = {"keyPath": rule.get("keyPath"), "valueName": rule.get("valueName")}
            elif rule["kind"] == "file":
                key = (rule.get("path"), rule.get("fileOrFolderName"))
                files[key] = {"path": rule.get("path"), "fileOrFolderName": rule.get("fileOrFolderName")}
    return {"registry": list(regs.values()), "files": list(files.values())}


def _ps_array(items: list[dict], fields: list[tuple[str, str]]) -> str:
    """Render a list of dicts as a PowerShell array-of-hashtables literal."""
    lines = []
    for it in items:
        pairs = "; ".join(
            f"{ps_key} = '{(it.get(src) or '').replace(chr(39), chr(39) * 2)}'"
            for ps_key, src in fields
        )
        lines.append(f"  @{{ {pairs} }}")
    return "@(\n" + ",\n".join(lines) + "\n)" if lines else "@()"


def generate_collector(conn: sqlite3.Connection, case_id: int, errors_only: bool = True) -> tuple[str, dict]:
    """Return (powershell_script, targets). Empty targets => nothing to collect."""
    targets = collect_targets(conn, case_id, errors_only=errors_only)
    reg_arr = _ps_array(targets["registry"], [("KeyPath", "keyPath"), ("ValueName", "valueName")])
    file_arr = _ps_array(targets["files"], [("Path", "path"), ("Name", "fileOrFolderName")])

    script = f"""<#
  RCA supplemental collector (auto-generated for case {case_id}).
  Run on the affected device, then feed the JSON back with:
      rca supplemental -c {case_id} --file <output.json>
#>
param([string]$Out = "rca-supplemental-$env:COMPUTERNAME.json")
$ErrorActionPreference = 'SilentlyContinue'

$Registry = {reg_arr}
$Files = {file_arr}

function To-Provider($keyPath) {{
    $p = $keyPath -replace '^HKEY_LOCAL_MACHINE','HKLM' -replace '^HKEY_CURRENT_USER','HKCU'
    $p = $p -replace '^HKLM\\\\','HKLM:\\' -replace '^HKCU\\\\','HKCU:\\'
    return $p
}}

$regOut = foreach ($t in $Registry) {{
    $prov = To-Provider $t.KeyPath
    $val = $null; $present = $false
    if ($t.ValueName) {{
        $item = Get-ItemProperty -Path $prov -Name $t.ValueName -ErrorAction SilentlyContinue
        if ($null -ne $item -and $null -ne $item.$($t.ValueName)) {{
            $present = $true; $val = "$($item.$($t.ValueName))"
        }}
    }} else {{
        $present = Test-Path -Path $prov
    }}
    [pscustomobject]@{{ key_path = $t.KeyPath; value_name = $t.ValueName
                       present = $present; value_type = 'sz'; value_data = $val }}
}}

$fileOut = foreach ($t in $Files) {{
    $full = if ($t.Name) {{ Join-Path $t.Path $t.Name }} else {{ $t.Path }}
    $f = Get-Item -LiteralPath $full -ErrorAction SilentlyContinue
    [pscustomobject]@{{ path = $full; present = [bool]$f
                       version = $(if ($f) {{ $f.VersionInfo.FileVersion }} else {{ $null }})
                       size = $(if ($f) {{ $f.Length }} else {{ $null }})
                       modified_utc = $(if ($f) {{ $f.LastWriteTimeUtc.ToString('o') }} else {{ $null }}) }}
}}

$result = [pscustomobject]@{{
    schema = '{SCHEMA}'
    machine = $env:COMPUTERNAME
    collected_utc = (Get-Date).ToUniversalTime().ToString('o')
    registry = @($regOut)
    files = @($fileOut)
}}
$result | ConvertTo-Json -Depth 5 | Set-Content -Path $Out -Encoding UTF8
Write-Host "Wrote $Out"
"""
    return script, targets


# --- ingestion ---------------------------------------------------------------

def _supplemental_bundle(conn: sqlite3.Connection, case_id: int, json_path: str,
                         machine: str | None, collected: str | None) -> int:
    row = conn.execute(
        "SELECT * FROM bundles WHERE case_id = ? AND kind = 'supplemental' LIMIT 1", (case_id,)
    ).fetchone()
    if row:
        # replace its prior facts
        conn.execute("DELETE FROM registry_values WHERE bundle_id = ?", (row["id"],))
        conn.execute("DELETE FROM file_facts WHERE bundle_id = ?", (row["id"],))
        conn.execute(
            "UPDATE bundles SET source_path=?, machine_name=?, collected_utc=?, ingested_utc=? WHERE id=?",
            (json_path, machine, collected, now_utc_iso(), row["id"]),
        )
        return row["id"]
    # inherit tz from the primary bundle so any future timestamps align
    tz = conn.execute(
        "SELECT tz_offset_minutes FROM bundles WHERE case_id=? AND tz_offset_minutes IS NOT NULL LIMIT 1",
        (case_id,)).fetchone()
    cur = conn.execute(
        """INSERT INTO bundles (case_id, kind, source_path, machine_name, collected_utc,
                                ingested_utc, tz_offset_minutes)
           VALUES (?, 'supplemental', ?, ?, ?, ?, ?)""",
        (case_id, json_path, machine, collected, now_utc_iso(),
         tz["tz_offset_minutes"] if tz else None),
    )
    return cur.lastrowid


def ingest_supplemental(conn: sqlite3.Connection, case_id: int, json_path: str) -> dict:
    with open(json_path, "r", encoding="utf-8-sig") as fh:
        data = json.load(fh)
    bundle_id = _supplemental_bundle(conn, case_id, json_path,
                                     data.get("machine"), data.get("collected_utc"))

    n_reg = n_file = 0
    for item in data.get("registry", []):
        key_path = item.get("key_path")
        if not key_path:
            continue
        vname = item.get("value_name") or None
        present = bool(item.get("present"))
        if present:
            vtype = item.get("value_type") or "sz"
            vdata = item.get("value_data")
        else:
            vtype = "absent" if vname else "key-absent"
            vdata = None
        conn.execute(
            """INSERT INTO registry_values
               (bundle_id, artifact_id, hive, key_path, value_name, value_type, value_data)
               VALUES (?, NULL, ?, ?, ?, ?, ?)""",
            (bundle_id, key_path.split("\\", 1)[0], key_path, vname, vtype, vdata),
        )
        n_reg += 1

    for item in data.get("files", []):
        path = item.get("path")
        if not path:
            continue
        conn.execute(
            """INSERT INTO file_facts (bundle_id, path, present, version, size, modified_utc)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (bundle_id, path, 1 if item.get("present") else 0,
             item.get("version"), item.get("size"), item.get("modified_utc")),
        )
        n_file += 1

    conn.commit()
    return {"bundle_id": bundle_id, "machine": data.get("machine"),
            "registry": n_reg, "files": n_file}
