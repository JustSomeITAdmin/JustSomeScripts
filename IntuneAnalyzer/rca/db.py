"""SQLite connection management and migration runner.

Uses `PRAGMA user_version` to track which migrations have been applied — no
external dependency, and the version travels inside the DB file itself.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

from rca import config
from rca.schema import MIGRATIONS


def connect(db_path: Path | None = None) -> sqlite3.Connection:
    """Open (creating if needed) the case DB with sane pragmas + migrations."""
    config.ensure_dirs()
    path = db_path or config.DB_PATH
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA busy_timeout = 5000")  # wait if another write holds the lock
    _migrate(conn)
    return conn


def _migrate(conn: sqlite3.Connection) -> None:
    current = conn.execute("PRAGMA user_version").fetchone()[0]
    target = len(MIGRATIONS)
    if current >= target:
        return
    for version in range(current, target):
        conn.executescript(MIGRATIONS[version])
        # user_version must be set via literal (no bind params in PRAGMA).
        conn.execute(f"PRAGMA user_version = {version + 1}")
    conn.commit()
