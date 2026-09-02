"""Command-line interface for the Intune RCA tool.

Phase 0 commands:
    rca new-case --symptom "..."        create an investigation
    rca cases                           list cases
    rca ingest --case N --zip FILE      catalog a diagnostics ZIP
    rca summary --case N                counts by category / collector / status
    rca artifacts --case N [filters]    browse the file catalog
"""

from __future__ import annotations

import posixpath
import sys
from pathlib import Path
from typing import Optional

import typer
from rich.console import Console
from rich.markup import escape
from rich.table import Table

# Make output safe on legacy consoles (cp1252): box-drawing, spinner, ellipsis.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass

from rca import config, db
from rca.engine import analyze_case
from rca.enrich import detection, graph, resolver
from rca.ruleset import CONFIDENCE_RANK, load_rules, LOAD_ERRORS
from rca.models import SEVERITY_RANK
from rca import errormap
from rca.ingest.ingest import ingest_zip
from rca.ingest.tzinfo import detect_offset
from rca.parsing import parse_case
from rca.regload import load_registry_case
from rca.report import render_html, render_markdown
from rca import supplemental
from rca.agent import llm as agent_llm
from rca.agent.investigator import investigate as run_investigation
from rca.etl import load_wu
from rca.timeutil import format_offset, parse_offset
from rca.util import human_size, hresult_hex, now_utc_iso

_SEV_STYLE = {"info": "dim", "warn": "yellow", "error": "red", "critical": "bold red"}


def _sev(s: str | None) -> str:
    return f"[{_SEV_STYLE.get(s, '')}]{s or ''}[/]"


def _short(text: str | None, n: int) -> str:
    text = (text or "").replace("\n", " ")
    if len(text) > n:
        text = text[: n - 1] + "…"
    # Escape so log/registry data like "[Win32App]" or "[registry …]" isn't
    # swallowed as Rich markup.
    return escape(text)

app = typer.Typer(add_completion=False, help="Intune diagnostics root-cause analysis.")
console = Console()


def _require_case(conn, case_id: int):
    row = conn.execute("SELECT * FROM cases WHERE id = ?", (case_id,)).fetchone()
    if row is None:
        console.print(f"[red]No case with id {case_id}.[/] Run `rca cases` to list.")
        raise typer.Exit(1)
    return row


@app.command("new-case")
def new_case(symptom: str = typer.Option(..., "--symptom", "-s", help="Symptom description.")):
    """Create a new investigation."""
    conn = db.connect()
    cur = conn.execute(
        "INSERT INTO cases (created_utc, symptom_text) VALUES (?, ?)",
        (now_utc_iso(), symptom),
    )
    conn.commit()
    console.print(f"[green]Created case {cur.lastrowid}[/]: {symptom}")


@app.command("cases")
def list_cases():
    """List all investigations."""
    conn = db.connect()
    rows = conn.execute(
        """SELECT c.id, c.created_utc, c.status, c.symptom_text,
                  COUNT(b.id) AS bundles
           FROM cases c LEFT JOIN bundles b ON b.case_id = c.id
           GROUP BY c.id ORDER BY c.id"""
    ).fetchall()
    if not rows:
        console.print("No cases yet. Create one with `rca new-case -s \"...\"`.")
        return
    table = Table(title="Cases")
    table.add_column("ID", justify="right")
    table.add_column("Created (UTC)")
    table.add_column("Status")
    table.add_column("Bundles", justify="right")
    table.add_column("Symptom")
    for r in rows:
        table.add_row(str(r["id"]), r["created_utc"], r["status"],
                      str(r["bundles"]), (r["symptom_text"] or "")[:70])
    console.print(table)


@app.command("ingest")
def ingest(
    case: int = typer.Option(..., "--case", "-c", help="Case id."),
    zip_path: Path = typer.Option(..., "--zip", "-z", help="Diagnostics ZIP path."),
    expand_cabs: bool = typer.Option(True, "--expand-cabs/--no-expand-cabs",
                                     help="Expand nested CABs (Defender, MDM)."),
    tz_offset: Optional[str] = typer.Option(None, "--tz-offset",
                                            help="Override device UTC offset, e.g. -4:00."),
):
    """Catalog a diagnostics ZIP into a case."""
    conn = db.connect()
    _require_case(conn, case)
    if not zip_path.exists():
        console.print(f"[red]ZIP not found:[/] {zip_path}")
        raise typer.Exit(1)

    override = None
    if tz_offset is not None:
        override = parse_offset(tz_offset)
        if override is None:
            console.print(f"[red]Bad --tz-offset:[/] {tz_offset} (expected like -4:00)")
            raise typer.Exit(1)

    with console.status(f"Cataloging {zip_path.name} ..."):
        result = ingest_zip(conn, case, zip_path, expand_cabs=expand_cabs,
                            tz_offset_override=override)

    tz = format_offset(result["tz_offset"])
    tz_extra = f" ({result['tz_name']})" if result["tz_name"] else ""
    console.print(f"[green]Ingested[/] bundle {result['bundle_id']} into case {case}")
    console.print(f"  machine:        {result['machine']}")
    console.print(f"  collected (UTC):{result['collected_utc']}")
    console.print(f"  device tz:      {tz}{tz_extra}  [dim]via {result['tz_source']}[/]")
    console.print(f"  files cataloged:{result['files_cataloged']}")
    console.print(f"  nested CABs:    {result['cabs_found']} "
                  f"(expanded {result['cabs_expanded']}, "
                  f"+{result['cab_children']} child files)")
    for err in result["cab_errors"]:
        console.print(f"  [yellow]cab warning:[/] {err}")


@app.command("summary")
def summary(case: int = typer.Option(..., "--case", "-c", help="Case id.")):
    """Show a breakdown of the catalog for a case."""
    conn = db.connect()
    _require_case(conn, case)

    bundles = conn.execute(
        "SELECT * FROM bundles WHERE case_id = ? ORDER BY id", (case,)
    ).fetchall()
    if not bundles:
        console.print("No bundles ingested yet. Run `rca ingest`.")
        return

    for b in bundles:
        tz = format_offset(b["tz_offset_minutes"])
        tz_extra = f" {b['tz_name']}" if b["tz_name"] else ""
        console.print(
            f"\n[bold]Bundle {b['id']}[/]  machine=[cyan]{b['machine_name']}[/]  "
            f"collected={b['collected_utc']}  "
            f"tz=[cyan]{tz}{tz_extra}[/]  "
            f"collection_hresult={hresult_hex(b['collection_hresult'])}"
        )

    bundle_ids = [b["id"] for b in bundles]
    placeholders = ",".join("?" * len(bundle_ids))

    cat = conn.execute(
        f"""SELECT category, COUNT(*) n, SUM(size) bytes
            FROM artifacts WHERE bundle_id IN ({placeholders})
            GROUP BY category ORDER BY n DESC""",
        bundle_ids,
    ).fetchall()
    t = Table(title="Artifacts by category")
    t.add_column("Category")
    t.add_column("Files", justify="right")
    t.add_column("Size", justify="right")
    for r in cat:
        t.add_row(r["category"], str(r["n"]), human_size(r["bytes"] or 0))
    console.print(t)

    failed = conn.execute(
        f"""SELECT COUNT(*) n FROM artifacts
            WHERE bundle_id IN ({placeholders}) AND collection_status = 'error'""",
        bundle_ids,
    ).fetchone()["n"]
    if failed:
        console.print(f"[yellow]{failed} collection items failed on the device "
                      f"(see `rca artifacts -c {case} --status error`).[/]")


@app.command("artifacts")
def artifacts(
    case: int = typer.Option(..., "--case", "-c", help="Case id."),
    category: Optional[str] = typer.Option(None, "--category", help="Filter by category."),
    status: Optional[str] = typer.Option(None, "--status", help="ok | error."),
    contains: Optional[str] = typer.Option(None, "--contains", help="Substring of rel_path."),
    limit: int = typer.Option(40, "--limit", "-n", help="Max rows."),
):
    """Browse the file catalog for a case."""
    conn = db.connect()
    _require_case(conn, case)

    where = ["b.case_id = ?"]
    params: list = [case]
    if category:
        where.append("a.category = ?"); params.append(category)
    if status:
        where.append("a.collection_status = ?"); params.append(status)
    if contains:
        where.append("a.rel_path LIKE ?"); params.append(f"%{contains}%")
    params.append(limit)

    rows = conn.execute(
        f"""SELECT a.id, a.category, a.collector_type, a.collection_status,
                   a.collection_hresult, a.size, a.rel_path
            FROM artifacts a JOIN bundles b ON b.id = a.bundle_id
            WHERE {' AND '.join(where)}
            ORDER BY a.collection_status DESC, a.category, a.rel_path
            LIMIT ?""",
        params,
    ).fetchall()

    if not rows:
        console.print("No matching artifacts.")
        return

    t = Table(title=f"Artifacts (case {case})")
    t.add_column("ID", justify="right")
    t.add_column("Category")
    t.add_column("St")
    t.add_column("HRESULT")
    t.add_column("Size", justify="right")
    t.add_column("Name")
    for r in rows:
        st = "[red]err[/]" if r["collection_status"] == "error" else "ok"
        # The meaningful part is the filename tail (incl. "cab!/inner"); the
        # "(N) <CollectorType> ..." prefix is captured in other columns.
        name = posixpath.basename(r["rel_path"]) or r["rel_path"]
        t.add_row(
            str(r["id"]), r["category"] or "", st,
            hresult_hex(r["collection_hresult"]) or "",
            human_size(r["size"] or 0),
            name[:70],
        )
    console.print(t)


def _case_tz(conn, case_id) -> tuple[int | None, str | None]:
    """Return (offset_minutes, tz_name) for a case (first bundle that has one)."""
    row = conn.execute(
        """SELECT tz_offset_minutes, tz_name FROM bundles
           WHERE case_id = ? AND tz_offset_minutes IS NOT NULL ORDER BY id LIMIT 1""",
        (case_id,),
    ).fetchone()
    if row:
        return row["tz_offset_minutes"], row["tz_name"]
    return None, None


@app.command("tz")
def tz(
    case: int = typer.Option(..., "--case", "-c", help="Case id."),
    offset: Optional[str] = typer.Option(None, "--offset",
                                         help="Set offset manually, e.g. -4:00. Omit to auto-detect."),
):
    """Show / set / re-detect the device timezone for a case's bundles."""
    conn = db.connect()
    _require_case(conn, case)
    bundles = conn.execute("SELECT * FROM bundles WHERE case_id = ? ORDER BY id", (case,)).fetchall()
    if not bundles:
        console.print("No bundles. Run `rca ingest` first.")
        return

    manual = None
    if offset is not None:
        manual = parse_offset(offset)
        if manual is None:
            console.print(f"[red]Bad --offset:[/] {offset} (expected like -4:00)")
            raise typer.Exit(1)

    changed = False
    for b in bundles:
        if manual is not None:
            off, name, src = manual, None, "manual"
        elif offset is None and Path(b["source_path"]).exists():
            off, name, src = detect_offset(Path(b["source_path"]))
        else:
            off, name, src = b["tz_offset_minutes"], b["tz_name"], b["tz_source"]
        conn.execute(
            "UPDATE bundles SET tz_offset_minutes=?, tz_name=?, tz_source=? WHERE id=?",
            (off, name, src, b["id"]),
        )
        changed = changed or (off != b["tz_offset_minutes"])
        extra = f" ({name})" if name else ""
        console.print(f"  bundle {b['id']} [{b['machine_name']}]: "
                      f"{format_offset(off)}{extra}  [dim]via {src}[/]")
    conn.commit()
    if changed:
        console.print("[yellow]Offset changed - run "
                      f"`rca parse -c {case} --category all --reparse` to apply.[/]")


@app.command("parse")
def parse(
    case: int = typer.Option(..., "--case", "-c", help="Case id."),
    category: str = typer.Option("ime_log", "--category",
                                 help="ime_log | eventlog | registry | all."),
    reparse: bool = typer.Option(False, "--reparse", help="Re-parse already-parsed artifacts."),
):
    """Parse artifacts into the timeline (events) and registry state."""
    conn = db.connect()
    _require_case(conn, case)

    do_events = category in ("ime_log", "eventlog", "all")
    do_registry = category in ("registry", "all")

    if do_events:
        event_cat = "all" if category == "all" else category
        with console.status(f"Parsing {event_cat} ... (evtx shells out to PowerShell)"):
            result = parse_case(conn, case, categories=(event_cat,), reparse=reparse)
        if "error" in result and not do_registry:
            console.print(f"[red]{result['error']}[/]")
            raise typer.Exit(1)
        if "error" not in result:
            console.print(
                f"[green]Parsed[/] {result['artifacts_parsed']} artifact(s), "
                f"skipped {result['artifacts_skipped']}, "
                f"errors {result['artifacts_error']}, "
                f"emitted [bold]{result['events']}[/] events."
            )
            for src, n in result["by_source"].items():
                console.print(f"  {src}: {n} events")

    if do_registry:
        with console.status("Parsing registry exports ..."):
            reg = load_registry_case(conn, case, reparse=reparse)
        console.print(
            f"[green]Registry[/] {reg['reg_files']} file(s), "
            f"{reg['values']} values, [bold]{reg['apps']}[/] installed apps."
        )


@app.command("timeline")
def timeline(
    case: int = typer.Option(..., "--case", "-c", help="Case id."),
    source: Optional[str] = typer.Option(None, "--source", help="e.g. IME."),
    severity: Optional[str] = typer.Option(None, "--severity", help="info|warn|error."),
    actor: Optional[str] = typer.Option(None, "--actor", help="App id (prefix ok)."),
    contains: Optional[str] = typer.Option(None, "--contains", help="Substring of message."),
    utc: bool = typer.Option(False, "--utc", help="Show UTC instead of device-local time."),
    limit: int = typer.Option(40, "--limit", "-n"),
):
    """Show the event timeline for a case (sorted by true UTC; shown local by default)."""
    conn = db.connect()
    _require_case(conn, case)
    where, params = ["case_id = ?"], [case]
    if source:
        where.append("source = ?"); params.append(source)
    if severity:
        where.append("severity = ?"); params.append(severity)
    if actor:
        where.append("actor LIKE ?"); params.append(f"{actor}%")
    if contains:
        where.append("message LIKE ?"); params.append(f"%{contains}%")
    params.append(limit)
    rows = conn.execute(
        f"""SELECT ts_utc, ts_local, severity, source, event_code, actor, message
            FROM events WHERE {' AND '.join(where)}
            ORDER BY ts_utc IS NULL, ts_utc LIMIT ?""",
        params,
    ).fetchall()
    if not rows:
        console.print("No matching events.")
        return
    _render_events(rows, f"Timeline (case {case})", conn, case, utc)


def _render_events(rows, title, conn, case, utc: bool) -> None:
    """Shared event table renderer with local/UTC clock selection."""
    offset_min, tz_name = _case_tz(conn, case)
    if utc:
        clock = "UTC"
    else:
        clock = format_offset(offset_min) + (f" {tz_name}" if tz_name else "")
        if offset_min is None:
            clock += " - not detected; run `rca tz`"
    t = Table(title=f"{title} - times in [bold]{clock}[/]")
    t.add_column("Time"); t.add_column("Sev"); t.add_column("Src")
    t.add_column("Code"); t.add_column("App"); t.add_column("Message")
    for r in rows:
        primary, fallback = (r["ts_utc"], r["ts_local"]) if utc else (r["ts_local"], r["ts_utc"])
        shown = primary or (f"{fallback}*" if fallback else "")
        t.add_row(
            _short(shown, 26), _sev(r["severity"]), r["source"],
            r["event_code"] or "", (r["actor"] or "")[:8], _short(r["message"], 80),
        )
    console.print(t)
    if any((r["ts_local"] if not utc else r["ts_utc"]) is None for r in rows):
        console.print("[dim]* shown in the other clock (this source lacks the selected one).[/]")


@app.command("search")
def search(
    query: str = typer.Argument(..., help="Full-text query over event messages."),
    case: int = typer.Option(..., "--case", "-c", help="Case id."),
    utc: bool = typer.Option(False, "--utc", help="Show UTC instead of device-local time."),
    limit: int = typer.Option(40, "--limit", "-n"),
):
    """Full-text search across the event timeline (FTS5)."""
    conn = db.connect()
    _require_case(conn, case)
    rows = conn.execute(
        """SELECT e.ts_utc, e.ts_local, e.severity, e.source, e.event_code, e.actor, e.message
           FROM events_fts f JOIN events e ON e.id = f.rowid
           WHERE f.events_fts MATCH ? AND e.case_id = ?
           ORDER BY e.ts_utc IS NULL, e.ts_utc LIMIT ?""",
        (query, case, limit),
    ).fetchall()
    if not rows:
        console.print("No matches.")
        return
    _render_events(rows, f"Search: {query!r} (case {case})", conn, case, utc)


@app.command("apps")
def apps(
    case: int = typer.Option(..., "--case", "-c", help="Case id."),
    errors_only: bool = typer.Option(False, "--errors-only", help="Only apps with errors."),
    limit: int = typer.Option(40, "--limit", "-n"),
):
    """Per-app rollup from IME events (the app-centric view of outcomes)."""
    conn = db.connect()
    _require_case(conn, case)
    having = "HAVING errors > 0" if errors_only else ""
    # Only GUID-shaped actors are apps; evtx provider names also land in `actor`.
    guid_like = "________-____-____-____-____________"
    rows = conn.execute(
        f"""SELECT e.actor,
                   COUNT(*) AS events,
                   SUM(CASE WHEN e.severity IN ('error','critical') THEN 1 ELSE 0 END) AS errors,
                   MAX(CASE WHEN e.event_code IS NOT NULL THEN e.event_code END) AS sample_code,
                   m.display_name, m.publisher
            FROM events e
            LEFT JOIN app_map m ON m.app_guid = e.actor
            WHERE e.case_id = ? AND e.actor IS NOT NULL
                  AND LENGTH(e.actor) = 36 AND e.actor LIKE '{guid_like}'
            GROUP BY e.actor {having}
            ORDER BY errors DESC, events DESC
            LIMIT ?""",
        (case, limit),
    ).fetchall()
    if not rows:
        console.print("No app-attributed events. Run `rca parse` first.")
        return
    unresolved = sum(1 for r in rows if not r["display_name"])
    t = Table(title=f"Apps seen in IME logs (case {case})")
    t.add_column("App"); t.add_column("Publisher")
    t.add_column("Events", justify="right"); t.add_column("Errors", justify="right")
    t.add_column("Sample code")
    for r in rows:
        err = f"[red]{r['errors']}[/]" if r["errors"] else "0"
        name = r["display_name"] or f"[dim]{r['actor']}[/]"
        t.add_row(name, r["publisher"] or "", str(r["events"]), err, r["sample_code"] or "")
    console.print(t)
    if unresolved:
        console.print(f"[dim]{unresolved} unresolved GUID(s). Run "
                      f"`rca resolve -c {case}` (Graph) or `rca set-app-name`.[/]")


@app.command("analyze")
def analyze(case: int = typer.Option(..., "--case", "-c", help="Case id.")):
    """Run the rule engine and produce ranked findings."""
    conn = db.connect()
    _require_case(conn, case)
    with console.status("Running rules ..."):
        r = analyze_case(conn, case)
    for err in LOAD_ERRORS:
        console.print(f"[yellow]custom rule failed to load:[/] {err}")
    for err in r.get("errors", []):
        console.print(f"[yellow]rule error:[/] {err}")
    console.print(f"[green]Analyzed[/] case {case}: {r['findings']} finding(s), "
                  f"{r['evidence']} evidence link(s). See `rca findings -c {case}`.")


@app.command("run")
def run(
    symptom: str = typer.Option(..., "--symptom", "-s", help="Symptom description."),
    zip_path: Path = typer.Option(..., "--zip", "-z", help="Diagnostics ZIP path."),
    tz_offset: Optional[str] = typer.Option(None, "--tz-offset",
                                            help="Override device UTC offset, e.g. -4:00."),
):
    """One shot: new-case + ingest + parse (all categories + registry) + analyze."""
    if not zip_path.exists():
        console.print(f"[red]ZIP not found:[/] {zip_path}")
        raise typer.Exit(1)
    override = None
    if tz_offset is not None:
        override = parse_offset(tz_offset)
        if override is None:
            console.print(f"[red]Bad --tz-offset:[/] {tz_offset} (expected like -4:00)")
            raise typer.Exit(1)

    conn = db.connect()
    case = conn.execute("INSERT INTO cases (created_utc, symptom_text) VALUES (?, ?)",
                        (now_utc_iso(), symptom)).lastrowid
    conn.commit()
    console.print(f"[green]Created case {case}[/]")

    with console.status(f"Cataloging {zip_path.name} ..."):
        ing = ingest_zip(conn, case, zip_path, expand_cabs=True, tz_offset_override=override)
    console.print(f"  machine {ing['machine']}  collected {ing['collected_utc']}  "
                  f"tz {format_offset(ing['tz_offset'])}  files {ing['files_cataloged']}")

    with console.status("Parsing IME + event logs ... (evtx shells out to PowerShell)"):
        parsed = parse_case(conn, case, categories=("all",), reparse=False)
    if "error" in parsed:
        console.print(f"[red]{parsed['error']}[/]")
        raise typer.Exit(1)
    console.print("  events: " + ", ".join(f"{s} {n}" for s, n in parsed["by_source"].items()))

    with console.status("Parsing registry exports ..."):
        reg = load_registry_case(conn, case, reparse=False)
    console.print(f"  registry: {reg['values']} values, {reg['apps']} installed apps")

    with console.status("Running rules ..."):
        r = analyze_case(conn, case)
    for err in LOAD_ERRORS + list(r.get("errors", [])):
        console.print(f"[yellow]rule problem:[/] {err}")
    console.print(f"[green]Analyzed[/] case {case}: {r['findings']} finding(s). "
                  f"See `rca findings -c {case}`.")


# ---------------------------------------------------------------------------
# Investigation primitives: the queries that every case needed hand-written.
# ---------------------------------------------------------------------------

def _ts_arg(v: str | None) -> str | None:
    """Accept '2026-09-02 11:50' or '2026-09-02T11:50'; events store 'T'."""
    return v.replace(" ", "T") if v else None


@app.command("window")
def window(
    case: int = typer.Option(..., "--case", "-c", help="Case id."),
    frm: str = typer.Option(..., "--from", help="Start, device-local, e.g. 2026-09-02 11:50"),
    to: str = typer.Option(..., "--to", help="End, device-local."),
    source: Optional[str] = typer.Option(None, "--source", help="IME | evtx | MSI | WU."),
    actor: Optional[str] = typer.Option(None, "--actor", help="Provider/app substring."),
    contains: Optional[str] = typer.Option(None, "--contains", help="Message substring."),
    quiet: bool = typer.Option(True, "--quiet/--noisy",
                               help="Drop WMI-Activity / Processor-Power chatter."),
    utc: bool = typer.Option(False, "--utc"),
    limit: int = typer.Option(80, "--limit", "-n"),
):
    """Every event in a time window (the 'what happened between X and Y' question)."""
    conn = db.connect()
    _require_case(conn, case)
    where, params = ["case_id = ?", "ts_local BETWEEN ? AND ?"], [case, _ts_arg(frm), _ts_arg(to)]
    if source:
        where.append("source = ?"); params.append(source)
    if actor:
        where.append("actor LIKE ?"); params.append(f"%{actor}%")
    if contains:
        where.append("message LIKE ?"); params.append(f"%{contains}%")
    if quiet:
        where.append("(actor IS NULL OR (actor NOT LIKE '%WMI-Activity%' "
                     "AND actor NOT LIKE '%Kernel-Processor-Power%'))")
    params.append(limit)
    rows = conn.execute(
        f"""SELECT ts_utc, ts_local, severity, source, event_code, actor, message
            FROM events WHERE {' AND '.join(where)} ORDER BY ts_utc LIMIT ?""", params).fetchall()
    if not rows:
        console.print("No events in that window.")
        return
    _render_events(rows, f"Window {frm} .. {to} (case {case})", conn, case, utc)


@app.command("boots")
def boots(
    case: int = typer.Option(..., "--case", "-c", help="Case id."),
    since: Optional[str] = typer.Option(None, "--since", help="Device-local date/time prefix."),
    standby: bool = typer.Option(False, "--standby", help="Include Modern Standby enter/exit."),
    limit: int = typer.Option(60, "--limit", "-n"),
):
    """Boot / shutdown / restart-initiator / recovery chain — who rebooted the machine."""
    conn = db.connect()
    _require_case(conn, case)
    codes = ["12", "13", "1074", "41", "109", "24652", "24635", "24658", "6008"]
    if standby:
        codes += ["506", "507"]
    where = ["case_id = ?", "source = 'evtx'", f"event_code IN ({','.join('?' * len(codes))})",
             "(actor LIKE '%Kernel-General%' OR actor LIKE '%Kernel-Power%' OR actor = 'User32' "
             "OR actor LIKE '%BitLocker-Driver%' OR actor = 'EventLog')"]
    params: list = [case, *codes]
    if since:
        where.append("ts_local >= ?"); params.append(_ts_arg(since))
    rows = conn.execute(
        f"""SELECT ts_local, ts_utc, actor, event_code, message FROM events
            WHERE {' AND '.join(where)} ORDER BY ts_utc""", params).fetchall()
    if not rows:
        console.print("No boot-chain events (System log parsed at info level?).")
        return
    import re
    from datetime import datetime
    t = Table(title=f"Boot chain (case {case}) - device-local time")
    t.add_column("Time"); t.add_column("Event"); t.add_column("Detail")
    last_down = None
    shown = 0
    for r in rows[-limit:]:
        code, msg = r["event_code"], " ".join((r["message"] or "").split())
        detail = ""
        if code == "12" and "Kernel-General" in (r["actor"] or ""):
            ev = "BOOT"
            if last_down:
                try:
                    gap = (datetime.fromisoformat(r["ts_utc"]) - datetime.fromisoformat(last_down)).total_seconds() / 3600
                    detail = f"off {gap:.1f}h" if gap >= 1 else f"down {gap*60:.0f} min"
                except (TypeError, ValueError):
                    pass
            last_down = None
        elif code == "13" and "Kernel-General" in (r["actor"] or ""):
            ev, last_down = "shutdown", r["ts_utc"]
        elif code == "1074":
            ev = "restart-init"
            m = re.search(r"The process (\S+)", msg); rs = re.search(r"reason: (.*?) Reason Code", msg)
            detail = (m.group(1).split("\\")[-1] if m else "?") + (f" - {rs.group(1)[:50]}" if rs else "")
        elif code == "41":
            ev, detail = "UNEXPECTED (power loss/crash)", ""
        elif code == "6008":
            ev = "unexpected shutdown"
        elif code == "109":
            ev = "power-action"; m = re.search(r"Action: Power Action (\w+)", msg); detail = m.group(1) if m else ""
        elif code in ("24652", "24635", "24658"):
            ev = "BITLOCKER RECOVERY"
            detail = {"24652": "recovery password used", "24635": "PCR mismatch",
                      "24658": "Secure Boot config changed"}[code]
        elif code in ("506", "507"):
            ev = "standby-enter" if code == "506" else "standby-exit"
            m = re.search(r"Reason: (.*)", msg); detail = m.group(1)[:40] if m else ""
        else:
            continue
        style = "[red]" if ev.startswith(("BITLOCKER", "UNEXPECTED")) else ("[bold]" if ev == "BOOT" else "")
        t.add_row(r["ts_local"][:19], f"{style}{ev}{'[/]' if style else ''}", detail)
        shown += 1
    console.print(t)


_HS_RESULT = "[HS] new result = "


def _hs_runs(conn, case, since=None, policy=None):
    """Parse '[HS] new result' JSON lines -> dicts (policy, ts, result, outputs)."""
    import json
    import re
    where, params = ["case_id = ?", "source = 'IME'", "message LIKE ?"], [case, f"%{_HS_RESULT}%"]
    if since:
        where.append("ts_local >= ?"); params.append(_ts_arg(since))
    if policy:
        where.append("message LIKE ?"); params.append(f"%{policy}%")
    out = []
    for r in conn.execute(f"""SELECT ts_local, message FROM events WHERE {' AND '.join(where)}
                              ORDER BY ts_utc""", params):
        raw = r["message"].split(_HS_RESULT, 1)[-1]
        try:
            j = json.loads(raw[:raw.rfind("}") + 1])
        except ValueError:
            m = re.search(r'"PolicyId":"([0-9a-f-]{36})"', raw)
            j = {"PolicyId": m.group(1) if m else "?", "Result": "?"}
            for k in ("PreRemediationDetectScriptOutput", "RemediationScriptOutput",
                      "PostRemediationDetectScriptOutput"):
                g = re.search(k + r'":"((?:[^"\\]|\\.)*)"', raw)
                j[k] = g.group(1) if g else ""
        out.append({"policy": j.get("PolicyId", "?"), "ts": r["ts_local"][:19],
                    "result": j.get("Result"),
                    "pre": (j.get("PreRemediationDetectScriptOutput") or "").strip(),
                    "rem": (j.get("RemediationScriptOutput") or "").strip(),
                    "post": (j.get("PostRemediationDetectScriptOutput") or "").strip()})
    return out


@app.command("hs")
def hs(
    case: int = typer.Option(..., "--case", "-c", help="Case id."),
    since: Optional[str] = typer.Option(None, "--since", help="Device-local date/time prefix."),
    policy: Optional[str] = typer.Option(None, "--policy", help="PolicyId (prefix ok)."),
    resolve: bool = typer.Option(False, "--resolve", help="Fetch names/assignments from Graph (cached)."),
    all_runs: bool = typer.Option(False, "--all-runs", help="Every run, not just the latest per policy."),
    device_code: bool = typer.Option(False, "--device-code"),
):
    """Proactive-remediation runs on this device: which scripts ran, when, what they said."""
    conn = db.connect()
    _require_case(conn, case)
    runs = _hs_runs(conn, case, since, policy)
    if not runs:
        console.print("No '[HS] new result' lines (remediations not parsed, or none ran).")
        return
    by: dict[str, list] = {}
    for x in runs:
        by.setdefault(x["policy"], []).append(x)

    names = {r["policy_id"]: r for r in conn.execute("SELECT * FROM hs_map")}
    if resolve:
        from rca.enrich import graph
        from rca.util import now_utc_iso
        todo = [p for p in by if p not in names and len(p) == 36]
        if todo:
            token = graph.get_token(interactive=not device_code, device_code_prompt=console.print)
            with console.status(f"Resolving {len(todo)} health script(s) via Graph ..."):
                for p in todo:
                    d = graph.get_health_script(token, p) or {"displayName": "(not found)",
                                                              "publisher": "", "assignments": ""}
                    conn.execute("""INSERT OR REPLACE INTO hs_map
                                    (policy_id, display_name, publisher, assignments, fetched_utc)
                                    VALUES (?,?,?,?,?)""",
                                 (p, d["displayName"], d["publisher"], d["assignments"], now_utc_iso()))
            conn.commit()
            names = {r["policy_id"]: r for r in conn.execute("SELECT * FROM hs_map")}

    t = Table(title=f"Remediation runs (case {case})")
    t.add_column("Policy"); t.add_column("Last run"); t.add_column("Runs", justify="right")
    t.add_column("Detect output"); t.add_column("Remediation output")
    if resolve or names:
        t.add_column("Assigned to")
    for p, xs in sorted(by.items(), key=lambda kv: kv[1][-1]["ts"], reverse=True):
        n = names.get(p)
        label = (n["display_name"] if n and n["display_name"] else p[:8]) + f"\n[dim]{p[:8]}[/]"
        for x in (xs if all_runs else xs[-1:]):
            row = [label, x["ts"], str(len(xs)), _short(x["pre"], 60), _short(x["rem"] or x["post"], 40)]
            if resolve or names:
                row.append(_short(n["assignments"] if n else "", 45))
            t.add_row(*row)
    console.print(t)
    if not resolve and any(p not in names for p in by):
        console.print("[dim]Unnamed policies: add --resolve to fetch names/assignments from Graph.[/]")


_APP_PHASES = [
    (r"detection state: (\w+)", "detect", "{0}"),
    (r"applicationDetected: (\w+)", "detect", "script detection -> {0}"),
    (r"GRSManager\] (?:App with id: [0-9a-f-]{36} )?(.*)", "GRS", "{0}"),
    # IME service start replays each app's cached prior state — not a fresh report.
    (r"reporting state initialized.*?\"ResultantAppState\":(\w+).*?\"EnforcementState\":(\w+)",
     "cached", "prior state replayed at service start (appState={0} enforce={1})"),
    (r"Downloading app on session", "download", "content download started"),
    (r"Download state .*?\"NewValue\":\"(\w+)\"", "download", "state -> {0}"),
    (r"===Step=== InstallBehavior (\w+), Intent (\d)", "install", "starting ({0}, intent {1})"),
    (r"lpExitCode (\d+)", "install", "exit code {0}"),
    (r"lpExitCode is defined as (\w+)", "install", "-> {0}"),
    (r"Execution state .*?\"NewValue\":\"(\w+)\"", "enforce", "state -> {0}"),
    (r"\"ResultantAppState\":(\w+).*?\"DetectionState\":(\w+).*?\"EnforcementState\":(\w+).*?\"InternalVersion\":(\d+)",
     "report", "appState={0} detect={1} enforce={2} v{3}"),
    (r"Sending results to service\. session Guid", "report", "batch sent to service"),
    (r"Applicability check .*?applicability state: (\w+)", "applicable", "{0}"),
    (r"No action required", "enforce", "no action required"),
]


@app.command("app")
def app_story(
    guid: str = typer.Argument(..., help="App id (prefix ok)."),
    case: int = typer.Option(..., "--case", "-c", help="Case id."),
    since: Optional[str] = typer.Option(None, "--since", help="Device-local date/time prefix."),
    limit: int = typer.Option(60, "--limit", "-n"),
):
    """One app's story: policy arrival, detection, GRS, download, install, reports."""
    import re
    conn = db.connect()
    _require_case(conn, case)
    if len(guid) < 36:
        hit = conn.execute("""SELECT DISTINCT actor FROM events WHERE case_id = ? AND actor LIKE ?
                              AND LENGTH(actor) = 36 LIMIT 2""", (case, f"{guid}%")).fetchall()
        if len(hit) != 1:
            console.print(f"[red]{'Ambiguous' if hit else 'Unknown'} app prefix {guid}[/]")
            raise typer.Exit(1)
        guid = hit[0]["actor"]
    name = conn.execute("SELECT display_name FROM app_map WHERE app_guid = ?", (guid,)).fetchone()
    where, params = ["case_id = ?", "source = 'IME'", "(actor = ? OR message LIKE ?)"], [case, guid, f"%{guid}%"]
    if since:
        where.append("ts_local >= ?"); params.append(_ts_arg(since))
    rows = conn.execute(f"""SELECT ts_local, message FROM events WHERE {' AND '.join(where)}
                            ORDER BY ts_utc""", params).fetchall()
    story = []
    pats = [(re.compile(p, re.S), ph, fmt) for p, ph, fmt in _APP_PHASES]
    rev_rx = re.compile(re.escape(guid) + r"_(\d+)\.ps1")
    seen_revs: set[str] = set()
    for r in rows:
        msg = " ".join(r["message"].split())
        # A new detection-script revision = the updated app policy reached the
        # device; first sighting in ANY line (the "is saved" line isn't always logged).
        rv = rev_rx.search(msg)
        if rv and rv.group(1) not in seen_revs:
            seen_revs.add(rv.group(1))
            story.append((r["ts_local"][:19], "policy", f"detection script rev {rv.group(1)} first seen"))
        for rx, phase, fmt in pats:
            m = rx.search(msg)
            if m:
                story.append((r["ts_local"][:19], phase, fmt.format(*m.groups())))
                break
    if not story:
        console.print("No story lines for that app in the IME log window.")
        return
    t = Table(title=f"App story: {name['display_name'] if name else guid} (case {case})")
    t.add_column("Time"); t.add_column("Phase"); t.add_column("Detail")
    for ts, ph, d in story[-limit:]:
        t.add_row(ts, ph, _short(d, 90))
    console.print(t)
    if len(story) > limit:
        console.print(f"[dim]{len(story) - limit} earlier line(s) hidden; -n to show more.[/]")


@app.command("web")
def web(
    host: str = typer.Option("127.0.0.1", "--host", help="Bind address (localhost only by default)."),
    port: int = typer.Option(8000, "--port", "-p", help="Port."),
    open_browser: bool = typer.Option(True, "--open/--no-open", help="Open a browser tab."),
):
    """Launch the local web UI (FastAPI + HTMX) over the case DB."""
    import uvicorn
    from rca.web.app import create_app

    url = f"http://{host}:{port}/"
    console.print(f"[green]Intune RCA web UI[/] at [bold]{url}[/]  (Ctrl+C to stop)")
    if open_browser:
        import threading, webbrowser
        threading.Timer(1.0, lambda: webbrowser.open(url)).start()
    uvicorn.run(create_app(), host=host, port=port, log_level="warning")


@app.command("investigate")
def investigate(
    case: int = typer.Option(..., "--case", "-c", help="Case id."),
    model: Optional[str] = typer.Option(None, "--model", help="Override the local model (e.g. qwen2.5:14b)."),
    max_steps: int = typer.Option(14, "--max-steps", help="Tool-call budget for the agent."),
    trace: bool = typer.Option(False, "--trace", help="Show the tools the agent called."),
):
    """LLM agent: investigate a case via the read-only tools and write an RCA report."""
    conn = db.connect()
    _require_case(conn, case)
    try:
        provider = agent_llm.get_provider(model=model)
        provider.ping()
    except agent_llm.LLMError as exc:
        console.print(f"[red]LLM not ready:[/] {exc}")
        raise typer.Exit(1)

    console.print(f"[dim]model: {provider.label} · read-only · up to {max_steps} steps[/]")
    steps_seen = []

    def on_step(n, names):
        steps_seen.append(names)
        console.print(f"[dim]  step {n}: {', '.join(names)}[/]")

    try:
        with console.status("Investigating (local model is thinking) ..."):
            result = run_investigation(conn, case, provider, max_steps=max_steps, on_step=on_step)
    except agent_llm.LLMError as exc:
        console.print(f"[red]LLM error:[/] {exc}")
        raise typer.Exit(1)

    console.print(f"\n[bold]Investigation report[/] (case {case}, {result['steps']} step(s), "
                  f"{len(result['trace'])} tool call(s))\n")
    from rich.markdown import Markdown
    console.print(Markdown(result["report"]))

    if trace:
        console.print("\n[dim]--- tool calls ---[/]")
        for t in result["trace"]:
            console.print(f"[dim]  {t['step']}. {t['tool']}({t['args']})[/]")


@app.command("rules")
def rules_list():
    """List the rules that will run (built-in + your custom_rules/)."""
    loaded = load_rules()
    t = Table(title="Loaded rules")
    t.add_column("Rule"); t.add_column("Source")
    for fn, source in loaded:
        style = "" if source == "built-in" else "cyan"
        t.add_row(fn.__name__, f"[{style}]{source}[/]" if style else source)
    console.print(t)
    rows = db.connect().execute("SELECT id, name, enabled, severity FROM user_rules ORDER BY id").fetchall()
    if rows:
        t2 = Table(title="No-code rules (web-authored)")
        t2.add_column("ID", justify="right"); t2.add_column("Name")
        t2.add_column("On"); t2.add_column("Sev")
        for r in rows:
            t2.add_row(str(r["id"]), r["name"], "yes" if r["enabled"] else "no", r["severity"])
        console.print(t2)
    console.print(f"[dim]Drop *.py rules into {config.RULES_DIR}; add no-code rules in the web UI (/rules).[/]")
    for err in LOAD_ERRORS:
        console.print(f"[yellow]load error:[/] {err}")


@app.command("errormap")
def errormap_list(
    fetch_hunter: bool = typer.Option(False, "--fetch-hunter",
                                      help="Download/refresh the Error Hunter catalog "
                                           "(errorhunter.msnugget.com) as an offline fallback."),
    code: Optional[str] = typer.Option(None, "--code",
                                       help="Look up one code through the full chain."),
):
    """Show known error codes (edit error_codes.json to add/correct)."""
    if fetch_hunter:
        with console.status("Fetching Error Hunter catalog ..."):
            sizes = errormap.fetch_hunter()
        for name, n in sizes.items():
            console.print(f"  [green]fetched[/] {name} ({human_size(n)})")
    if code:
        info = errormap.lookup(code)
        if info:
            src = " [dim](via Error Hunter)[/]" if info.get("source") == "errorhunter" else ""
            console.print(f"[bold]{code}[/] [{info.get('family','')}] {info.get('label','')}{src}")
            console.print(f"  {info.get('recommendation','')}")
        else:
            console.print(f"[yellow]No entry for {code}[/] (curated map + Error Hunter).")
        return
    data = errormap.load()
    t = Table(title="Error code map")
    t.add_column("Code"); t.add_column("Family"); t.add_column("Meaning")
    for c, info in sorted(data.items()):
        t.add_row(c, info.get("family", ""), _short(info.get("label", ""), 60))
    console.print(t)
    console.print(f"[dim]Editable file: {config.ERROR_MAP_PATH}[/]")
    n = errormap.hunter_count()
    console.print(f"[dim]Error Hunter fallback: "
                  f"{f'{n} codes cached offline' if n else 'not fetched (rca errormap --fetch-hunter)'}[/]")


def _finding_sort_key(row):
    return (SEVERITY_RANK.get(row["severity"], 0),
            CONFIDENCE_RANK.get(row["confidence"], 0),
            row["evidence"])


@app.command("findings")
def findings(case: int = typer.Option(..., "--case", "-c", help="Case id.")):
    """Show ranked findings for a case."""
    conn = db.connect()
    _require_case(conn, case)
    rows = conn.execute(
        """SELECT f.id, f.severity, f.confidence, f.title,
                  COUNT(fe.event_id) AS evidence
           FROM findings f LEFT JOIN finding_evidence fe ON fe.finding_id = f.id
           WHERE f.case_id = ? GROUP BY f.id""",
        (case,),
    ).fetchall()
    if not rows:
        console.print(f"No findings. Run `rca analyze -c {case}` first.")
        return
    rows = sorted(rows, key=_finding_sort_key, reverse=True)
    t = Table(title=f"Findings (case {case})")
    t.add_column("ID", justify="right"); t.add_column("Sev"); t.add_column("Conf")
    t.add_column("Ev", justify="right"); t.add_column("Finding")
    for r in rows:
        t.add_row(str(r["id"]), _sev(r["severity"]), r["confidence"],
                  str(r["evidence"]), _short(r["title"], 70))
    console.print(t)
    console.print(f"[dim]Detail: `rca finding -c {case} -i <ID>`[/]")


@app.command("finding")
def finding(
    case: int = typer.Option(..., "--case", "-c", help="Case id."),
    finding_id: int = typer.Option(..., "--id", "-i", help="Finding id."),
    utc: bool = typer.Option(False, "--utc", help="Show evidence times in UTC."),
):
    """Show one finding with its summary, recommendation, and evidence."""
    conn = db.connect()
    _require_case(conn, case)
    f = conn.execute("SELECT * FROM findings WHERE id = ? AND case_id = ?",
                     (finding_id, case)).fetchone()
    if f is None:
        console.print(f"[red]No finding {finding_id} in case {case}.[/]")
        raise typer.Exit(1)
    console.print(f"\n[bold]{escape(f['title'])}[/]")
    console.print(f"  severity={_sev(f['severity'])}  confidence={f['confidence']}  "
                  f"rule={f['rule_id']}")
    console.print(f"\n[bold]Summary[/]\n  {escape(f['summary'])}")
    console.print(f"\n[bold]Recommendation[/]\n  {escape(f['recommendation'])}")

    ev = conn.execute(
        """SELECT e.ts_local, e.ts_utc, e.severity, e.source, e.event_code, e.actor, e.message
           FROM finding_evidence fe JOIN events e ON e.id = fe.event_id
           WHERE fe.finding_id = ? ORDER BY e.ts_utc IS NULL, e.ts_utc LIMIT 15""",
        (finding_id,),
    ).fetchall()
    if ev:
        console.print("\n[bold]Evidence[/]")
        _render_events(ev, "Evidence", conn, case, utc)


@app.command("etl")
def etl_cmd(
    case: int = typer.Option(..., "--case", "-c", help="Case id."),
    reparse: bool = typer.Option(False, "--reparse", help="Re-decode even if already done."),
):
    """On-demand: decode WindowsUpdate ETLs into the timeline (source 'WU')."""
    conn = db.connect()
    _require_case(conn, case)
    console.print("[dim]Decoding WindowsUpdate ETLs (Get-WindowsUpdateLog — can take a minute)…[/]")
    with console.status("Converting + parsing ETL ..."):
        r = load_wu(conn, case, reparse=reparse)
    if r["note"]:
        console.print(f"[yellow]{r['note']}[/]")
    if r["etl_files"] == 0 and not r["note"]:
        console.print("No WindowsUpdate ETLs pending (already decoded? use --reparse).")
        return
    console.print(f"[green]ETL decoded[/]: {r['etl_files']} file(s) -> {r['log_kb']} KB log -> "
                  f"[bold]{r['events']}[/] WU warning/error events. "
                  f"View: `rca timeline -c {case} --source WU --severity error`")


@app.command("report")
def report(
    case: int = typer.Option(..., "--case", "-c", help="Case id."),
    fmt: str = typer.Option("html", "--format", help="html | md."),
    out: Optional[Path] = typer.Option(None, "--out", "-o", help="Output path."),
    no_redact: bool = typer.Option(False, "--no-redact",
                                   help="Include UPNs/hostnames/SIDs (sensitive)."),
):
    """Export a shareable RCA report for a case (redacted by default)."""
    conn = db.connect()
    _require_case(conn, case)
    redact = not no_redact
    if fmt == "md":
        content, ext = render_markdown(conn, case, redact=redact), "md"
    else:
        content, ext = render_html(conn, case, redact=redact), "html"
    if content is None:
        console.print(f"[red]No case {case}.[/]")
        raise typer.Exit(1)
    out = out or (Path.cwd() / f"case-{case}-report.{ext}")
    out.write_text(content, encoding="utf-8")
    note = "[green]redacted[/]" if redact else "[red]NOT redacted (sensitive)[/]"
    console.print(f"[green]Wrote[/] {out}  ({note})")


@app.command("inventory")
def inventory(
    case: int = typer.Option(..., "--case", "-c", help="Case id."),
    contains: Optional[str] = typer.Option(None, "--contains", help="Substring of app name."),
    limit: int = typer.Option(60, "--limit", "-n"),
):
    """List installed apps from the device's Uninstall registry keys."""
    conn = db.connect()
    _require_case(conn, case)
    where = ["b.case_id = ?"]
    params: list = [case]
    if contains:
        where.append("a.display_name LIKE ?"); params.append(f"%{contains}%")
    params.append(limit)
    rows = conn.execute(
        f"""SELECT a.display_name, a.display_version, a.publisher, a.scope
            FROM installed_apps a JOIN bundles b ON b.id = a.bundle_id
            WHERE {' AND '.join(where)}
            ORDER BY a.display_name COLLATE NOCASE LIMIT ?""",
        params,
    ).fetchall()
    if not rows:
        total = conn.execute(
            """SELECT COUNT(*) n FROM installed_apps a JOIN bundles b ON b.id = a.bundle_id
               WHERE b.case_id = ?""", (case,)).fetchone()["n"]
        if total == 0:
            console.print(f"No installed apps yet. Run `rca parse -c {case} --category registry`.")
        else:
            console.print("No installed apps match that filter.")
        return
    t = Table(title=f"Installed apps (case {case})")
    t.add_column("Name"); t.add_column("Version"); t.add_column("Publisher"); t.add_column("Scope")
    for r in rows:
        t.add_row(_short(r["display_name"], 50), r["display_version"] or "",
                  _short(r["publisher"], 30), r["scope"])
    console.print(t)


@app.command("regquery")
def regquery(
    case: int = typer.Option(..., "--case", "-c", help="Case id."),
    key: Optional[str] = typer.Option(None, "--key", help="Substring of key path."),
    name: Optional[str] = typer.Option(None, "--name", help="Substring of value name."),
    limit: int = typer.Option(40, "--limit", "-n"),
):
    """Query raw registry values (verify detection rules, TLS posture, etc.)."""
    conn = db.connect()
    _require_case(conn, case)
    where = ["b.case_id = ?", "rv.value_type != 'key'"]
    params: list = [case]
    if key:
        where.append("rv.key_path LIKE ?"); params.append(f"%{key}%")
    if name:
        where.append("rv.value_name LIKE ?"); params.append(f"%{name}%")
    params.append(limit)
    rows = conn.execute(
        f"""SELECT rv.key_path, rv.value_name, rv.value_type, rv.value_data
            FROM registry_values rv JOIN bundles b ON b.id = rv.bundle_id
            WHERE {' AND '.join(where)}
            ORDER BY rv.key_path, rv.value_name LIMIT ?""",
        params,
    ).fetchall()
    if not rows:
        console.print("No matching registry values.")
        return
    t = Table(title=f"Registry values (case {case})")
    t.add_column("Key"); t.add_column("Value"); t.add_column("Type"); t.add_column("Data")
    for r in rows:
        t.add_row(_short(r["key_path"], 54), _short(r["value_name"], 24),
                  r["value_type"], _short(r["value_data"], 40))
    console.print(t)


@app.command("graph-test")
def graph_test(
    device_code: bool = typer.Option(False, "--device-code",
                                     help="Use device-code flow instead of opening a browser."),
):
    """Verify Microsoft Graph auth (opens a browser to sign in by default)."""
    mode = graph.auth_mode()
    console.print(f"Auth mode: [cyan]{mode}[/]"
                  + ("" if mode == "app-only" else
                     " [dim](no app registration — well-known public client)[/]"))
    try:
        if mode == "app-only" or device_code:
            with console.status("Acquiring token ..."):
                token = graph.get_token(interactive=False,
                                        device_code_prompt=lambda m: console.print(f"[bold]{m}[/]"))
        else:
            console.print("Opening browser for sign-in ...")
            token = graph.get_token(interactive=True)
        console.print(f"[green]Token acquired[/] ({len(token)} chars).")
        if mode != "app-only":
            who = graph.whoami(token)
            if who:
                console.print(f"Signed in as: [cyan]{who}[/]")
        console.print("[green]Graph is reachable.[/]")
    except graph.GraphNotConfigured as exc:
        console.print(f"[red]Graph error:[/] {exc}")
        raise typer.Exit(1)


@app.command("resolve")
def resolve(
    case: int = typer.Option(..., "--case", "-c", help="Case id."),
    errors_only: bool = typer.Option(False, "--errors-only",
                                     help="Only resolve apps that have errors (fast)."),
    force: bool = typer.Option(False, "--force", help="Re-resolve even if cached."),
    device_code: bool = typer.Option(False, "--device-code",
                                     help="Use device-code flow instead of opening a browser."),
):
    """Resolve the case's app GUIDs to names via Microsoft Graph (cached, batched)."""
    conn = db.connect()
    _require_case(conn, case)
    interactive = not device_code and graph.auth_mode() != "app-only"
    if interactive:
        console.print("Signing in (browser opens only if no cached token) ...")

    from rich.progress import BarColumn, Progress, TextColumn

    try:
        with Progress(TextColumn("[progress.description]{task.description}"),
                      BarColumn(), TextColumn("{task.completed}/{task.total}"),
                      console=console, transient=True) as prog:
            task = prog.add_task("Resolving apps via Graph", total=None)

            def on_progress(done, total):
                prog.update(task, total=total, completed=done)

            r = resolver.resolve_case(
                conn, case, errors_only=errors_only, force=force, interactive=interactive,
                device_code_prompt=lambda m: console.print(f"[bold]{m}[/]"),
                progress_cb=on_progress,
            )
    except graph.GraphNotConfigured as exc:
        console.print(f"[yellow]Graph not available:[/] {exc}")
        console.print("[dim]You can still map names manually with `rca set-app-name`.[/]")
        raise typer.Exit(1)
    console.print(
        f"[green]Resolved[/] {r['resolved']} | cached {r['cached']} | "
        f"not-found {r['not_found']} | errors {r['errors']} | total {r['total']}"
    )


@app.command("detection")
def detection_cmd(
    case: int = typer.Option(..., "--case", "-c", help="Case id."),
    all_apps: bool = typer.Option(False, "--all", help="All apps (default: only failing)."),
    force: bool = typer.Option(False, "--force", help="Re-fetch even if cached."),
    device_code: bool = typer.Option(False, "--device-code", help="Device-code auth."),
):
    """Fetch Win32 detection rules from Graph and check them against this device."""
    conn = db.connect()
    _require_case(conn, case)
    interactive = not device_code and graph.auth_mode() != "app-only"
    errors_only = not all_apps
    if interactive:
        console.print("Signing in (browser opens only if no cached token) ...")
    try:
        from rich.progress import BarColumn, Progress, TextColumn
        with Progress(TextColumn("[progress.description]{task.description}"), BarColumn(),
                      TextColumn("{task.completed}/{task.total}"), console=console,
                      transient=True) as prog:
            t = prog.add_task("Fetching detection rules", total=None)
            r = detection.fetch_case(
                conn, case, errors_only=errors_only, force=force, interactive=interactive,
                device_code_prompt=lambda m: console.print(f"[bold]{m}[/]"),
                progress_cb=lambda d, tot: prog.update(t, total=tot, completed=d))
    except graph.GraphNotConfigured as exc:
        console.print(f"[yellow]Graph not available:[/] {exc}")
        raise typer.Exit(1)
    console.print(f"[green]Detection rules[/] fetched {r['fetched']} | cached {r['cached']} "
                  f"| not-found {r['not_found']} | errors {r['errors']}")

    guids = resolver.case_app_guids(conn, case, errors_only=errors_only)
    _vstyle = {"satisfied": "green", "not_satisfied": "red", "unknown": "yellow"}
    shown = 0
    for g in guids:
        vs = detection.verdicts_for(conn, case, g)
        if not vs:
            continue
        shown += 1
        nm = conn.execute("SELECT display_name FROM app_map WHERE app_guid=?", (g,)).fetchone()
        title = (nm["display_name"] if nm and nm["display_name"] else g)
        console.print(f"\n[bold]{title}[/]  [dim]{g}[/]")
        t2 = Table(show_header=True)
        t2.add_column("Detection rule"); t2.add_column("On this device")
        for rule, status, detail in vs:
            t2.add_row(_short(rule["summary"], 64),
                       f"[{_vstyle.get(status,'')}]{status}[/] — {_short(detail, 44)}")
        console.print(t2)
    if not shown:
        console.print("[dim]No cached detection rules to show (apps may not be Win32, "
                      "or none failing).[/]")


@app.command("profiles")
def profiles(
    case: int = typer.Option(..., "--case", "-c", help="Case id."),
    refresh: bool = typer.Option(False, "--refresh", help="Refetch from Graph."),
):
    """Configuration-profile states for the case's device (via Graph)."""
    from rca.enrich import profiles as prof
    conn = db.connect()
    _require_case(conn, case)
    console.print("[dim]Signing in (browser opens only if no cached token) ...[/]")
    try:
        r = prof.fetch_profile_states(conn, case, refresh=refresh)
    except graph.GraphNotConfigured as exc:
        console.print(f"[yellow]Graph not available:[/] {exc}")
        raise typer.Exit(1)
    if "error" in r:
        console.print(f"[red]{r['error']}[/]")
        raise typer.Exit(1)

    _pstyle = {"compliant": "green", "remediated": "green", "notApplicable": "dim",
               "nonCompliant": "yellow", "error": "red", "conflict": "red"}
    rows = conn.execute(
        """SELECT * FROM profile_states WHERE case_id = ? AND setting_name IS NULL
           ORDER BY CASE WHEN state IN ('error','conflict') THEN 0
                         WHEN state = 'nonCompliant' THEN 1 ELSE 2 END, display_name""",
        (case,)).fetchall()
    t = Table(title=f"Configuration profiles ({len(rows)}; "
                    f"{'refetched' if r['fetched'] else 'cached — use --refresh'})")
    t.add_column("Profile"); t.add_column("Platform"); t.add_column("State"); t.add_column("User")
    for p in rows:
        t.add_row(_short(p["display_name"], 55), p["platform_type"] or "",
                  f"[{_pstyle.get(p['state'], '')}]{p['state']}[/]", p["user_principal"] or "")
    console.print(t)
    for p in rows:
        if p["state"] not in ("error", "conflict", "nonCompliant"):
            continue
        for s in conn.execute(
            """SELECT setting_name, setting_state, error_code FROM profile_states
               WHERE case_id = ? AND profile_id = ? AND setting_name IS NOT NULL""",
                (case, p["profile_id"])).fetchall():
            code = f" ({hresult_hex(int(s['error_code']))})" if s["error_code"] else ""
            console.print(f"  [red]{_short(p['display_name'], 40)}[/] → "
                          f"{_short(s['setting_name'], 60)}: {s['setting_state']}{code}")


@app.command("collect-script")
def collect_script(
    case: int = typer.Option(..., "--case", "-c", help="Case id."),
    all_apps: bool = typer.Option(False, "--all", help="All apps (default: only failing)."),
    out: Optional[Path] = typer.Option(None, "--out", "-o", help="Output .ps1 path."),
):
    """Generate a PowerShell collector for the registry/files detection rules need.

    Run `rca detection` first so the rules are cached.
    """
    conn = db.connect()
    _require_case(conn, case)
    script, targets = supplemental.generate_collector(conn, case, errors_only=not all_apps)
    n = len(targets["registry"]) + len(targets["files"])
    if n == 0:
        console.print("Nothing to collect — no registry/file detection rules cached. "
                      f"Run `rca detection -c {case}` first (or those apps detect by "
                      "product code/script).")
        return
    out = out or (config.REPO_ROOT / f"rca-collect-case{case}.ps1")
    out.write_text(script, encoding="utf-8")
    console.print(f"[green]Wrote collector[/] {out}")
    console.print(f"  targets: {len(targets['registry'])} registry value(s), "
                  f"{len(targets['files'])} file(s)")
    console.print("\nRun it [bold]on the affected device[/], then bring back the JSON:")
    console.print(f"  powershell -ExecutionPolicy Bypass -File {out.name}")
    console.print(f"  rca supplemental -c {case} --file rca-supplemental-<PC>.json")


@app.command("supplemental")
def supplemental_cmd(
    case: int = typer.Option(..., "--case", "-c", help="Case id."),
    file: Path = typer.Option(..., "--file", "-f", help="Supplemental JSON from the collector."),
):
    """Ingest a supplemental collection JSON so detection rules can be evaluated."""
    conn = db.connect()
    _require_case(conn, case)
    if not file.exists():
        console.print(f"[red]File not found:[/] {file}")
        raise typer.Exit(1)
    r = supplemental.ingest_supplemental(conn, case, str(file))
    console.print(f"[green]Ingested supplemental[/] (bundle {r['bundle_id']}, "
                  f"machine {r['machine']}): {r['registry']} registry value(s), "
                  f"{r['files']} file(s).")
    console.print(f"[dim]Re-run `rca detection -c {case}` / `rca analyze -c {case}` "
                  "to use it.[/]")


@app.command("set-app-name")
def set_app_name(
    guid: str = typer.Option(..., "--guid", "-g", help="App GUID."),
    name: str = typer.Option(..., "--name", "-n", help="Display name."),
    publisher: Optional[str] = typer.Option(None, "--publisher", "-p"),
):
    """Manually map an app GUID to a name (offline; cached like Graph results)."""
    conn = db.connect()
    resolver.upsert(conn, guid.lower(), name, publisher, source="manual")
    conn.commit()
    console.print(f"[green]Mapped[/] {guid} -> {name}")


if __name__ == "__main__":
    app()
