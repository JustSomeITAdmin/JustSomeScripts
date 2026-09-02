"""Catalog a diagnostics ZIP into the DB, then expand any nested CABs.

Design choices that keep a 2 GB / ~1,900-file package tractable:
  * We stream-hash every entry straight from the ZIP — nothing is extracted to
    disk during cataloging.
  * Only CABs are *materialized* (written out) so expand.exe can open them; the
    files inside become child artifacts.
Deep parsing of contents is a later phase; ingest just builds the map.
"""

from __future__ import annotations

import re
import sqlite3
import zipfile
from pathlib import Path

from rca import config
from rca.ingest import cabs, classify
from rca.ingest.manifest import parse_manifest
from rca.ingest.tzinfo import detect_offset
from rca.util import now_utc_iso, sha256_stream

# DiagLogs-<machine>-<YYYYMMDD>T<HHMMSS>Z.zip
_NAME_RE = re.compile(
    r"^DiagLogs-(?P<machine>.+)-(?P<ts>\d{8}T\d{6}Z)\.zip$", re.IGNORECASE
)


def _parse_zip_name(zip_path: Path) -> tuple[str | None, str | None]:
    m = _NAME_RE.match(zip_path.name)
    if not m:
        return None, None
    machine = m.group("machine")
    ts = m.group("ts")  # 20260622T104511Z -> 2026-06-22T10:45:11Z
    iso = f"{ts[0:4]}-{ts[4:6]}-{ts[6:8]}T{ts[9:11]}:{ts[11:13]}:{ts[13:15]}Z"
    return machine, iso


def _hash_file(path: Path) -> str:
    with open(path, "rb") as f:
        digest, _ = sha256_stream(f)
    return digest


def _zip_mtime_iso(info: zipfile.ZipInfo) -> str:
    y, mo, d, h, mi, s = info.date_time
    return f"{y:04d}-{mo:02d}-{d:02d}T{h:02d}:{mi:02d}:{s:02d}"


def ingest_zip(
    conn: sqlite3.Connection,
    case_id: int,
    zip_path: Path,
    expand_cabs: bool = True,
    tz_offset_override: int | None = None,
) -> dict:
    """Ingest one ZIP into a case. Returns a summary dict."""
    zip_path = Path(zip_path)
    if not zip_path.exists():
        raise FileNotFoundError(zip_path)

    machine, collected = _parse_zip_name(zip_path)
    if tz_offset_override is not None:
        tz_offset, tz_name, tz_source = tz_offset_override, None, "manual"
    else:
        tz_offset, tz_name, tz_source = detect_offset(zip_path)

    with zipfile.ZipFile(zip_path) as z:
        # results.xml -> collection identity
        manifest = None
        for n in z.namelist():
            if n.lower().endswith("results.xml") and "/" not in n.strip("/"):
                manifest = parse_manifest(z.read(n))
                break

        cur = conn.execute(
            """INSERT INTO bundles
               (case_id, kind, source_path, sha256, machine_name, collected_utc,
                collection_id, collection_hresult, ingested_utc,
                tz_offset_minutes, tz_name, tz_source)
               VALUES (?, 'intune_diag', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                case_id,
                str(zip_path),
                _hash_file(zip_path),
                machine,
                collected,
                manifest.collection_id if manifest else None,
                manifest.hresult if manifest else None,
                now_utc_iso(),
                tz_offset,
                tz_name,
                tz_source,
            ),
        )
        bundle_id = cur.lastrowid

        cab_artifacts: list[tuple[int, str]] = []  # (artifact_id, rel_path)
        n_files = 0

        for info in z.infolist():
            if info.is_dir():
                continue
            rel_path = info.filename
            top_name, _ = classify.split_top(rel_path)
            top = classify.parse_top_level(top_name)
            ext = classify.ext_of(rel_path)
            category = classify.categorize(top, rel_path, ext)

            with z.open(info) as fp:
                digest, size = sha256_stream(fp)

            cur = conn.execute(
                """INSERT INTO artifacts
                   (bundle_id, rel_path, top_index, collector_type,
                    collection_status, collection_hresult, category, ext, size,
                    sha256, mtime_utc)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    bundle_id, rel_path, top.index, top.collector_type,
                    top.status, top.hresult, category, ext, size, digest,
                    _zip_mtime_iso(info),
                ),
            )
            n_files += 1
            # Trigger CAB expansion by extension, not category: a CAB under a
            # Defender/MDM path is classified by that path (defender/mdm), so
            # keying off category would miss it.
            if ext == ".cab":
                cab_artifacts.append((cur.lastrowid, rel_path))

        conn.commit()

        n_cab_ok = 0
        n_cab_children = 0
        cab_errors: list[str] = []
        if expand_cabs and cab_artifacts:
            raw_dir = config.case_raw_dir(case_id)
            for artifact_id, rel_path in cab_artifacts:
                added, ok, err = _expand_one(
                    conn, z, bundle_id, artifact_id, rel_path, raw_dir
                )
                if ok:
                    n_cab_ok += 1
                    n_cab_children += added
                else:
                    cab_errors.append(f"{rel_path}: {err}")
            conn.commit()

    return {
        "bundle_id": bundle_id,
        "machine": machine,
        "collected_utc": collected,
        "tz_offset": tz_offset,
        "tz_name": tz_name,
        "tz_source": tz_source,
        "files_cataloged": n_files,
        "cabs_found": len(cab_artifacts),
        "cabs_expanded": n_cab_ok,
        "cab_children": n_cab_children,
        "cab_errors": cab_errors,
    }


def _expand_one(
    conn: sqlite3.Connection,
    z: zipfile.ZipFile,
    bundle_id: int,
    cab_artifact_id: int,
    cab_rel_path: str,
    raw_dir: Path,
) -> tuple[int, bool, str]:
    """Materialize one CAB, expand it, and catalog children. Returns (added, ok, err)."""
    cab_disk = raw_dir / cab_rel_path
    cab_disk.parent.mkdir(parents=True, exist_ok=True)
    with z.open(cab_rel_path) as src, open(cab_disk, "wb") as dst:
        while chunk := src.read(1 << 20):
            dst.write(chunk)

    conn.execute(
        "UPDATE artifacts SET materialized = 1, raw_path = ? WHERE id = ?",
        (str(cab_disk), cab_artifact_id),
    )

    dest_dir = Path(str(cab_disk) + ".extracted")
    ok, msg, files = cabs.expand_cab(cab_disk, dest_dir)
    if not ok:
        return 0, False, msg

    added = 0
    for f in files:
        inner_rel = f.relative_to(dest_dir).as_posix()
        ext = classify.ext_of(f.name)
        # children inherit nothing from the (N) naming; classify by path/ext.
        top = classify.TopLevel(None, "FoldersFiles", "ok", None, inner_rel)
        category = classify.categorize(top, f"{cab_rel_path}/{inner_rel}", ext)
        conn.execute(
            """INSERT INTO artifacts
               (bundle_id, parent_artifact_id, rel_path, collector_type,
                collection_status, category, ext, size, sha256, materialized, raw_path)
               VALUES (?, ?, ?, 'FoldersFiles', 'ok', ?, ?, ?, ?, 1, ?)""",
            (
                bundle_id, cab_artifact_id, f"{cab_rel_path}!/{inner_rel}",
                category, ext, f.stat().st_size, _hash_file(f), str(f),
            ),
        )
        added += 1
    return added, True, msg
