"""Editable error-code knowledge base.

Codes -> {family, label, confidence, recommendation}. Built-in defaults ship in
code; a JSON file at config.ERROR_MAP_PATH (default <repo>/error_codes.json) is
created on first use and merged on top, so you can add/correct codes by editing
that file — no code change, no reinstall. Rules, reports, and the future LLM
agent all read through here, so it's the single source of truth for "what does
this code mean."
"""

from __future__ import annotations

import json
import re

from rca import config

# Built-in seeds. The JSON file (user-editable) overrides/extends these.
# Meanings for the Intune/AppX/Windows codes are from Microsoft's published
# "Intune app installation error reference"; MSI/WU codes are the standard values.
def _c(family, label, recommendation, confidence="high"):
    return {"family": family, "label": label, "confidence": confidence,
            "recommendation": recommendation}


DEFAULTS: dict[str, dict] = {
    # --- Intune Win32 / app deployment ---
    "0x87D1041C": _c("Intune Win32", "installed but not detected",
        "Install completed but the detection rule didn't match (commonly the app was "
        "uninstalled, or detection doesn't match what the installer leaves). Verify the "
        "detection rule (file/registry/MSI product code) against the device; if MSI, "
        "confirm the ProductCode; if a script, run it and check its exit/output."),
    "0x87D30017": _c("Intune Win32", "Win32 app reported failed (enforcement)",
        "Not in Microsoft's published app-error list. Observed in this environment on "
        "uninstall-intent apps. Check the app's requirement rules and that the "
        "uninstall command actually clears the detection; review AppWorkload.log around "
        "these events.", confidence="low"),
    "0x8000FFFF": _c("Windows", "unexpected/catastrophic failure",
        "An unexpected error occurred. Check the installation logs and the Windows event "
        "logs around the failure time."),
    "0x80004005": _c("Windows", "unspecified error (E_FAIL)",
        "Generic failure. Correlate with the installer/MSI log and nearby event-log errors."),
    "0x80070002": _c("Windows", "file not found",
        "A required file or path was missing. Check the install command's working dir, "
        "content download, and that referenced files exist."),
    "0x80070005": _c("Windows", "access denied",
        "Permission denied. Confirm install context (system vs user) and that AV/EDR "
        "isn't blocking the IMECache/Content folders."),
    "0x80070032": _c("Windows", "the request is not supported (ERROR_NOT_SUPPORTED)",
        "The operation isn't supported in this state/context — often benign in WU traces; "
        "investigate only if it correlates with a user-visible failure."),
    "0x80091007": _c("Windows", "hash value is not correct",
        "Downloaded content is corrupt or altered. Re-download; check proxy/inspection "
        "devices that may be modifying content."),
    "0x800705B4": _c("Windows", "operation timed out",
        "A step exceeded its timeout. Check connectivity and whether the installer is "
        "waiting on something (prompt, service)."),
    "0xC0000142": _c("Windows", "DLL initialization failed",
        "A process failed to start (often a session-0/desktop-less context issue). Verify "
        "the app supports silent/system-context install."),
    "0x80040154": _c("Windows", "class not registered",
        "A required COM component isn't registered. Check prerequisites/runtimes."),
    # --- AppX / MSIX ---
    "0x80073CF0": _c("AppX", "package could not be opened (unsigned / publisher mismatch)",
        "Check the AppxPackaging/Operational event log; ensure the package is properly "
        "signed and the publisher matches."),
    "0x80073CF3": _c("AppX", "package conflict / dependency missing / wrong architecture",
        "Check AppXDeployment-Server log: a dependency is missing, it conflicts with an "
        "installed package, or the architecture is wrong."),
    "0x80073CFB": _c("AppX", "package already installed, reinstall blocked",
        "The same-version package is present but not bit-identical. Bump the version and "
        "re-sign, or remove the old package for all users first."),
    "0x80073CFF": _c("AppX", "sideloading not enabled",
        "Enable AllowAllTrustedApps / sideloading, or deploy via the Store."),
    # --- MSI / Windows Installer (decimal exit codes) ---
    "1603": _c("MSI", "fatal error during installation",
        "Open the .msi.log; find the first 'Return value 3' or failed custom action above "
        "the result line to locate the failing action."),
    "1618": _c("MSI", "another installation already in progress",
        "A concurrent MSI was running. IME usually retries; if persistent, check for a "
        "stuck msiexec or competing installer."),
    "1619": _c("MSI", "installation package could not be opened",
        "The .msi path is missing/inaccessible or the package is corrupt."),
    "1620": _c("MSI", "installation package could not be opened (invalid)",
        "The package is not a valid installer or is damaged."),
    "1622": _c("MSI", "error opening installation log file",
        "The specified log path is invalid/unwritable."),
    "1633": _c("MSI", "platform not supported",
        "The package doesn't support this architecture (e.g. x86 vs x64/ARM64)."),
    "1638": _c("MSI", "another version of this product is already installed",
        "Uninstall the existing version or use a major upgrade; check the detection/"
        "supersedence configuration."),
    "1639": _c("MSI", "invalid command-line argument",
        "Review the install/uninstall command line passed to msiexec."),
    "1605": _c("MSI", "action valid only for installed products",
        "An uninstall/repair targeted a product that isn't installed."),
    "1612": _c("MSI", "installation source unavailable",
        "The original install source is missing — needed for repair/uninstall."),
    "3010": _c("MSI", "success — reboot required",
        "Install succeeded; a restart is required to complete. Not a failure."),
    "3011": _c("MSI", "success — reboot required (uninstall)",
        "Uninstall succeeded; a restart is required to complete."),
    "0x80073712": _c("Windows", "component store corrupt (ERROR_SXS_COMPONENT_STORE_CORRUPT)",
        "Two variants. (a) Real store corruption: `DISM /Online /Cleanup-Image "
        "/RestoreHealth` + `sfc /scannow`, reboot, retry. (b) If DISM/SFC succeed "
        "but the update still fails: check CBS.log for 'Not able to find ...\\"
        "SoftwareDistribution\\Download\\...' right before the CorruptManifest mark — "
        "that's an incomplete DOWNLOAD (often a Feature-on-Demand payload like RSAT/"
        "DFS tools), not store corruption. Fix: stop wuauserv+bits, delete "
        "SoftwareDistribution\\Download, restart, re-scan; if it recurs, remove/"
        "re-add the FoD or install the CU manually from the Update Catalog. "
        "In-place repair upgrade is the last resort."),
    # --- Windows Update (well-known wuerror.h values) ---
    "0x80240016": _c("WU", "install not allowed right now (WU_E_INSTALL_NOT_ALLOWED)",
        "Another install was in progress or a reboot was pending. Usually transient; "
        "reboot and retry. Recurring: check for a wedged installer or pending-reboot "
        "state."),
    "0x80240009": _c("WU", "another conflicting operation in progress (WU_E_OPERATIONINPROGRESS)",
        "Two WU operations overlapped. Usually transient; investigate if persistent."),
    "0x8024000C": _c("WU", "no operation was required (WU_E_NOOP)",
        "WU determined nothing needed to be done — typically not an error."),
    "0x80248007": _c("WU", "requested info not in the data store (WU_E_DS_NODATA)",
        "The WU data store lacked expected data — often after a reset or first scan; "
        "investigate only if updates are actually failing."),
    "0x80240022": _c("WU", "all updates failed to install (WU_E_ALL_UPDATES_FAILED)",
        "Every update in the operation failed — check the WindowsUpdate timeline for the "
        "first underlying error."),
    # --- Windows numeric ---
    "1": _c("Windows", "incorrect function",
        "Review the Windows event logs around the failure with the install logs."),
    "2": _c("Windows", "the system cannot find the file specified",
        "A referenced file is missing; repair the system file or reinstall the app."),
}

_cache: dict | None = None


def _ensure_seed() -> None:
    if not config.ERROR_MAP_PATH.exists():
        config.ensure_dirs()
        config.ERROR_MAP_PATH.write_text(json.dumps(DEFAULTS, indent=2), encoding="utf-8")


def load() -> dict[str, dict]:
    global _cache
    if _cache is None:
        _ensure_seed()
        merged = dict(DEFAULTS)
        try:
            merged.update(json.loads(config.ERROR_MAP_PATH.read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError):
            pass
        _cache = merged
    return _cache


def lookup(code: str) -> dict | None:
    """Our curated map first; Error Hunter catalog (if fetched) as fallback."""
    return load().get(code) or _hunter_lookup(code)


# --- Error Hunter fallback (errorhunter.msnugget.com) ------------------------
# The site publishes its whole catalog as two static JS data files: a curated
# Intune knowledge base (Tier 1: code/title/description/cause/resolution/url)
# and a generic Windows/MSI/HRESULT/WU dictionary (Tier 2: symbol + message).
# `rca errormap --fetch-hunter` downloads both into HOME/errorhunter/ — the
# disk copy IS the cache; lookups after that are fully offline. Our own map
# always wins; Error Hunter only fills the gaps.

HUNTER_FILES = {
    "intune-errors.js": "https://errorhunter.msnugget.com/data/intune-errors.js",
    "win32-codes.js": "https://errorhunter.msnugget.com/data/win32-codes.js",
}
_hunter: dict[str, dict] | None = None


def hunter_dir():
    return config.HOME / "errorhunter"


def fetch_hunter(timeout: int = 30) -> dict[str, int]:
    """Download/refresh the Error Hunter data files. Returns bytes per file."""
    import requests
    try:  # behind corporate TLS inspection (Zscaler), trust the OS cert store
        import truststore
        truststore.inject_into_ssl()
    except ImportError:
        pass
    d = hunter_dir()
    d.mkdir(parents=True, exist_ok=True)
    sizes = {}
    for name, url in HUNTER_FILES.items():
        r = requests.get(url, timeout=timeout)
        r.raise_for_status()
        (d / name).write_text(r.text, encoding="utf-8")
        sizes[name] = len(r.text)
    global _hunter
    _hunter = None  # re-parse on next lookup
    return sizes


def _norm_variants(code: str) -> list[str]:
    """Key variants for a code: as-is, 0x-padded-upper hex, unsigned/signed decimal."""
    c = (code or "").strip()
    out = [c]
    m = re.fullmatch(r"0[xX]([0-9A-Fa-f]{1,8})", c)
    if m:
        h = m.group(1).upper().zfill(8)
        out.append("0x" + h)
        if h.startswith("8007"):  # FACILITY_WIN32 HRESULT wraps a plain Win32 code
            out.append(str(int(h[4:], 16)))
        # ponytail: only the 0x8007 facility is unwrapped — by far the most common
        # in Intune logs; other facilities fall through to "not found".
    elif re.fullmatch(r"-?\d+", c):
        n = int(c) & 0xFFFFFFFF
        out += [str(n), f"0x{n:08X}"]
    return out


def _parse_hunter() -> dict[str, dict]:
    """Parse the two JS data files into one lookup dict (empty if not fetched)."""
    d = hunter_dir()
    out: dict[str, dict] = {}

    # Tier 2 first so Tier-1 curated records overwrite on collision.
    w = d / "win32-codes.js"
    if w.exists():
        # rows look like: add(5, true, 5, 'ERROR_ACCESS_DENIED', 'Access is denied.', 'Win32');
        # ponytail: regex over generated rows; a handful of multi-line calls may be
        # missed — acceptable for a fallback dictionary.
        rx = re.compile(
            r"\(\s*(\d+)\s*,[^)']*?'([A-Za-z0-9_]+)'\s*,\s*'((?:[^'\\]|\\.)*)'\s*,\s*'(\w+)'\s*\)")
        for m in rx.finditer(w.read_text(encoding="utf-8", errors="replace")):
            unsigned, name, desc, source = (int(m.group(1)), m.group(2),
                                            m.group(3).replace("\\'", "'"), m.group(4))
            entry = {
                "family": source, "label": name, "confidence": "medium",
                "recommendation": f"{desc} (Error Hunter dictionary; check the log "
                                  f"line immediately before this code for the "
                                  f"component-specific failure.)",
                "source": "errorhunter",
            }
            for k in {str(unsigned), f"0x{unsigned:08X}"}:
                out[k] = entry
            if unsigned >= 0x80000000:
                out[str(unsigned - 2**32)] = entry

    i = d / "intune-errors.js"
    if i.exists():
        m = re.search(r"EH\.data\s*=\s*(\[.*\]);", i.read_text(encoding="utf-8", errors="replace"),
                      re.DOTALL)
        if m:
            try:
                records = json.loads(m.group(1))
            except json.JSONDecodeError:
                records = []
            for rec in records:
                fix = " ".join(x for x in (rec.get("cause"), rec.get("resolution")) if x)
                if rec.get("url"):
                    fix += f" Reference: {rec['url']}"
                entry = {
                    "family": rec.get("category") or "Intune",
                    "label": rec.get("title") or rec.get("symbol") or rec.get("code", ""),
                    "confidence": "medium",
                    "recommendation": fix or rec.get("description", ""),
                    "source": "errorhunter",
                }
                for k in {rec.get("code"), rec.get("hex"), str(rec.get("decimal", "")),
                          rec.get("symbol")}:
                    if k:
                        out[str(k)] = entry
    return out


def _hunter_lookup(code: str) -> dict | None:
    global _hunter
    if _hunter is None:
        _hunter = _parse_hunter()
    for k in _norm_variants(code):
        if k in _hunter:
            return _hunter[k]
    return None


def hunter_count() -> int:
    """Distinct entries in the fetched Error Hunter catalog (0 = not fetched)."""
    global _hunter
    if _hunter is None:
        _hunter = _parse_hunter()
    return len({id(v) for v in _hunter.values()})
