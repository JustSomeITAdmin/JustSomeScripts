"""Decode the Intune diagnostics package's self-describing layout.

Each top-level ZIP entry is named like:

    (10) RegistryKey HKLM_..._Winlogon export.reg
    (26) Command programfiles_windows_defender_mpcmdrun_exe_-GetFiles output.log
    (45) Events Application Events.evtx
    (63) FoldersFiles ProgramData_..._IntuneManagementExtension_Logs   (a folder)
    (1)  No Results - Error [0x80070001] RegistryKey HKLM_..._CloudManagedUpdate

So the top-level name encodes an index, a collector type, a success/error
status, and a human descriptor. We parse that here and assign each file a
semantic `category` used later to pick a parser.
"""

from __future__ import annotations

import posixpath
import re
from dataclasses import dataclass

# (N) at the start of every collected top-level entry.
_INDEX_RE = re.compile(r"^\((?P<idx>\d+)\)\s+(?P<rest>.*)$")
# "No Results - Error [0x........]" prefix on failed collections.
_ERROR_RE = re.compile(r"^No Results - Error \[(?P<code>0x[0-9A-Fa-f]+)\]\s*(?P<rest>.*)$")

_COLLECTOR_TYPES = ("RegistryKey", "Command", "Events", "FoldersFiles")


@dataclass
class TopLevel:
    """Parsed top-level entry metadata, shared by every file beneath it."""

    index: int | None
    collector_type: str | None   # RegistryKey|Command|Events|FoldersFiles|manifest
    status: str                  # ok | error
    hresult: int | None          # parsed from "Error [0x...]" when status == error
    descriptor: str              # the path-ish remainder of the name


def parse_top_level(top_name: str) -> TopLevel:
    """Parse the first path component of a ZIP entry into structured metadata."""
    if top_name.lower() == "results.xml":
        return TopLevel(None, "manifest", "ok", None, "results.xml")

    m = _INDEX_RE.match(top_name)
    if not m:
        return TopLevel(None, None, "ok", None, top_name)

    index = int(m.group("idx"))
    rest = m.group("rest")
    status = "ok"
    hresult: int | None = None

    err = _ERROR_RE.match(rest)
    if err:
        status = "error"
        hresult = int(err.group("code"), 16)
        # signed 32-bit normalization so it matches results.xml HRESULTs
        if hresult >= 0x80000000:
            hresult -= 0x100000000
        rest = err.group("rest")

    collector_type = None
    descriptor = rest
    for ct in _COLLECTOR_TYPES:
        if rest.startswith(ct):
            collector_type = ct
            descriptor = rest[len(ct):].strip()
            break

    return TopLevel(index, collector_type, status, hresult, descriptor)


def categorize(top: TopLevel, rel_path: str, ext: str) -> str:
    """Assign a semantic category used downstream to select a parser.

    Combines the collector type with path/extension heuristics. `rel_path` is
    the full path within the ZIP; `ext` is the lowercased file extension.
    """
    if top.collector_type == "manifest":
        return "manifest"
    if top.collector_type == "RegistryKey":
        return "registry"
    if top.collector_type == "Command":
        return "command_output"
    if top.collector_type == "Events":
        return "eventlog"

    # FoldersFiles (or unknown): refine on the path, then the extension.
    p = rel_path.lower()
    checks = (
        ("intunemanagementextension_logs", "ime_log"),
        ("epm_agent", "epm_log"),
        ("device_inventory_agent", "inventory_log"),
        ("windows_defender", "defender"),
        ("mpsupportfiles", "defender"),
        ("mdmdiagnostics", "mdm"),
        ("windowsupdate", "wu_etl"),
        ("usoshared", "wu_etl"),
        ("logs_cbs", "cbs"),
        ("setupdiag", "setupdiag"),
        ("measuredboot", "measuredboot"),
        ("diagnosticlogcsp", "diagcsp_etl"),
        ("winget", "winget_log"),
        ("panther", "panther"),
    )
    for needle, cat in checks:
        if needle in p:
            return cat

    by_ext = {
        ".etl": "etl",
        ".evtx": "eventlog",
        ".reg": "registry",
        ".cab": "nested_cab",
        ".html": "html_report",
        ".xml": "xml",
        ".log": "log",
        ".log_": "log",
    }
    return by_ext.get(ext, "other")


def split_top(rel_path: str) -> tuple[str, str]:
    """Return (top_level_component, remainder) for a forward-slash ZIP path."""
    parts = rel_path.split("/", 1)
    return parts[0], (parts[1] if len(parts) > 1 else "")


def ext_of(name: str) -> str:
    return posixpath.splitext(name)[1].lower()
