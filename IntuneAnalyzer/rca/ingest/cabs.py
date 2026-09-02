"""Expand nested CAB files using Windows' built-in expand.exe.

Intune packages embed CABs (MpSupportFiles.cab from Defender, mdmlogs-*.cab
from MDM diagnostics). We materialize the CAB to disk, expand it, and catalog
the contents as child artifacts so their inner logs become first-class.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

# Use the genuine Windows expand.exe, not the GNU `expand` on the Git Bash PATH.
_EXPAND = Path(os.environ.get("WINDIR", r"C:\Windows")) / "System32" / "expand.exe"


def expand_cab(cab_path: Path, dest_dir: Path) -> tuple[bool, str, list[Path]]:
    """Expand `cab_path` into `dest_dir`. Returns (ok, message, extracted_files)."""
    dest_dir.mkdir(parents=True, exist_ok=True)
    exe = str(_EXPAND) if _EXPAND.exists() else "expand"
    try:
        proc = subprocess.run(
            [exe, "-F:*", str(cab_path), str(dest_dir)],
            capture_output=True,
            text=True,
            timeout=300,
        )
    except FileNotFoundError:
        return False, "expand.exe not found", []
    except subprocess.TimeoutExpired:
        return False, "expand.exe timed out", []

    files = [p for p in dest_dir.rglob("*") if p.is_file()]
    if proc.returncode != 0 and not files:
        msg = (proc.stderr or proc.stdout or "expand failed").strip().splitlines()
        return False, (msg[-1] if msg else "expand failed"), []
    return True, f"extracted {len(files)} file(s)", files
