"""Small, dependency-free helpers shared across the package."""

from __future__ import annotations

import hashlib
from datetime import datetime, timezone
from typing import BinaryIO

_CHUNK = 1 << 20  # 1 MiB


def sha256_stream(fp: BinaryIO) -> tuple[str, int]:
    """Hash a binary stream in chunks. Returns (hex_digest, byte_count).

    Used to fingerprint every ZIP entry without extracting it to disk.
    """
    h = hashlib.sha256()
    total = 0
    while True:
        chunk = fp.read(_CHUNK)
        if not chunk:
            break
        total += len(chunk)
        h.update(chunk)
    return h.hexdigest(), total


def now_utc_iso() -> str:
    """Current UTC time as an ISO-8601 string (second precision, 'Z' suffix)."""
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def hresult_hex(value: int | None) -> str | None:
    """Render an HRESULT/Win32 code as 0xXXXXXXXX.

    Intune's results.xml stores HRESULTs as signed 32-bit ints
    (e.g. -2147024895). Normalize to the conventional unsigned hex form.
    """
    if value is None:
        return None
    return f"0x{value & 0xFFFFFFFF:08X}"


def human_size(num_bytes: int) -> str:
    size = float(num_bytes)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} B"
        size /= 1024
    return f"{size:.1f} TB"
