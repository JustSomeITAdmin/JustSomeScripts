"""Load collected .reg exports into registry_values + installed_apps.

Separate from parse_case (which builds the event timeline) because registry data
is point-in-time state, not time-series. Idempotent per artifact: re-running
replaces that artifact's rows.
"""

from __future__ import annotations

import sqlite3
import zipfile
from pathlib import Path

from rca.parsers.registry import parse_reg

_UNINSTALL = "\\uninstall\\"


def _decode(b: bytes) -> str:
    if b[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return b.decode("utf-16", errors="replace")
    if b[:3] == b"\xef\xbb\xbf":
        return b.decode("utf-8-sig", errors="replace")
    return b.decode("utf-8", errors="replace")


def _scope(key_path: str) -> str:
    k = key_path.lower()
    if "wow6432node" in k:
        return "HKLM-WOW6432"
    if k.startswith("hkey_current_user"):
        return "HKCU"
    return "HKLM"


def _read_text(row, zf) -> str:
    if row["materialized"] and row["raw_path"]:
        return _decode(Path(row["raw_path"]).read_bytes())
    if zf is None:
        raise RuntimeError("source ZIP unavailable")
    return _decode(zf.read(row["rel_path"]))


def load_registry_case(conn: sqlite3.Connection, case_id: int,
                       reparse: bool = False) -> dict:
    """Parse the case's .reg artifacts into the registry tables. Returns a summary."""
    bundles = conn.execute(
        "SELECT * FROM bundles WHERE case_id = ? ORDER BY id", (case_id,)
    ).fetchall()
    summary = {"reg_files": 0, "values": 0, "apps": 0}

    for b in bundles:
        status_filter = "" if reparse else "AND parsed_status = 'pending'"
        # MdmDiagReport_RegistryDump.reg (inside the mdmlogs CAB, category 'mdm')
        # is the full PolicyManager dump — the configuration-profile state.
        rows = conn.execute(
            f"""SELECT * FROM artifacts
                WHERE bundle_id = ?
                      AND (category = 'registry'
                           OR (category = 'mdm' AND lower(rel_path) LIKE '%registrydump.reg'))
                      AND collection_status = 'ok' AND size > 0 {status_filter}
                ORDER BY rel_path""",
            (b["id"],),
        ).fetchall()
        if not rows:
            continue

        zf = zipfile.ZipFile(b["source_path"]) if Path(b["source_path"]).exists() else None
        try:
            for row in rows:
                # idempotent replace for this artifact
                conn.execute("DELETE FROM registry_values WHERE artifact_id = ?", (row["id"],))
                conn.execute("DELETE FROM installed_apps WHERE artifact_id = ?", (row["id"],))
                try:
                    text = _read_text(row, zf)
                except Exception as exc:
                    conn.execute(
                        "UPDATE artifacts SET parsed_status='error', parser_name=? WHERE id=?",
                        (f"read-error: {exc}"[:200], row["id"]),
                    )
                    continue

                n_val, n_app = _load_one(conn, b["id"], row["id"], text)
                summary["reg_files"] += 1
                summary["values"] += n_val
                summary["apps"] += n_app
                conn.execute(
                    "UPDATE artifacts SET parsed_status='parsed', parser_name='registry' WHERE id=?",
                    (row["id"],),
                )
        finally:
            if zf is not None:
                zf.close()

    conn.commit()
    return summary


def _load_one(conn, bundle_id, artifact_id, text) -> tuple[int, int]:
    n_val = n_app = 0
    for block in parse_reg(text):
        # key-presence row
        conn.execute(
            """INSERT INTO registry_values
               (bundle_id, artifact_id, hive, key_path, value_name, value_type, value_data)
               VALUES (?, ?, ?, ?, NULL, 'key', NULL)""",
            (bundle_id, artifact_id, block.hive, block.key_path),
        )
        n_val += 1
        lower = {}
        for name, vtype, data in block.values:
            conn.execute(
                """INSERT INTO registry_values
                   (bundle_id, artifact_id, hive, key_path, value_name, value_type, value_data)
                   VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (bundle_id, artifact_id, block.hive, block.key_path, name, vtype, data),
            )
            n_val += 1
            if name:
                lower[name.lower()] = data

        # installed-app rows: Uninstall *subkeys* that carry a DisplayName
        kl = block.key_path.lower()
        if _UNINSTALL in kl and not kl.endswith("\\uninstall") and lower.get("displayname"):
            conn.execute(
                """INSERT INTO installed_apps
                   (bundle_id, artifact_id, scope, key_name, display_name, display_version,
                    publisher, install_date, uninstall_string, system_component)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    bundle_id, artifact_id, _scope(block.key_path),
                    block.key_path.rsplit("\\", 1)[-1],
                    lower.get("displayname"), lower.get("displayversion"),
                    lower.get("publisher"), lower.get("installdate"),
                    lower.get("uninstallstring"),
                    1 if lower.get("systemcomponent") == "1" else 0,
                ),
            )
            n_app += 1
    return n_val, n_app
