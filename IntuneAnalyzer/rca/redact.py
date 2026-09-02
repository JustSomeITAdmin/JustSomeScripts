"""Redaction for shareable output.

The database keeps real data (analysis needs it). Redaction is applied only when
content *leaves the machine* — i.e. exported reports — so a finding can go into a
ticket or to a colleague without UPNs, hostnames, SIDs, or user paths.

A Redactor combines case-specific literals (this device's machine name, the
tenant collection id) with generic patterns (email/UPN, SID, user profile path).
App GUIDs are intentionally left intact — they're Intune app ids, not PII, and
they're what makes a report actionable.
"""

from __future__ import annotations

import re
import sqlite3

_EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
_SID = re.compile(r"S-1-(?:\d+-){2,}\d+")
_USERPATH = re.compile(r"([A-Za-z]:\\Users\\)([^\\/\s\"'<>|]+)", re.I)


class Redactor:
    def __init__(self, literals: list[tuple[str, str]] | None = None):
        # literals: (value, placeholder); only redact reasonably distinctive ones.
        self._literals = [(re.compile(re.escape(v), re.I), ph)
                          for v, ph in (literals or []) if v and len(v) >= 4]

    def scrub(self, text: str | None) -> str:
        if not text:
            return text or ""
        for rx, ph in self._literals:
            text = rx.sub(ph, text)
        text = _EMAIL.sub("<EMAIL>", text)
        text = _SID.sub("<SID>", text)
        text = _USERPATH.sub(r"\1<USER>", text)
        return text


def build_redactor(conn: sqlite3.Connection, case_id: int) -> Redactor:
    """Build a redactor seeded with this case's machine names + collection ids."""
    literals: list[tuple[str, str]] = []
    for b in conn.execute(
        "SELECT machine_name, collection_id FROM bundles WHERE case_id = ?", (case_id,)
    ).fetchall():
        if b["machine_name"]:
            literals.append((b["machine_name"], "<HOST>"))
        if b["collection_id"]:
            literals.append((b["collection_id"], "<COLLECTION-ID>"))
    return Redactor(literals)
