"""FastAPI app for the local RCA web UI.

Server-rendered pages + HTMX fragments over the exact same SQLite core the CLI
uses. Bind to localhost only; no auth (single-user local tool). The agent route
runs the same read-only investigator as `rca investigate`.
"""

from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI, File, Form, Request, UploadFile
from fastapi.responses import HTMLResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from rca import config, db, errormap
from rca.agent import llm as agent_llm
from rca.agent.investigator import investigate as run_investigation
from rca.engine import analyze_case
from rca.enrich import detection, graph, resolver
from rca.etl import load_wu
from rca.ingest.ingest import ingest_zip
from rca.models import SEVERITY_RANK
from rca.parsing import parse_case
from rca.report import render_html, render_markdown
from rca.ruleset import CONFIDENCE_RANK, load_rules
from rca.timeutil import format_offset
from rca.util import now_utc_iso

WEB_DIR = Path(__file__).resolve().parent
_GUID_LIKE = "________-____-____-____-____________"
_HTMX_CDN = "https://unpkg.com/htmx.org@2.0.3/dist/htmx.min.js"

templates = Jinja2Templates(directory=str(WEB_DIR / "templates"))


def _ensure_htmx() -> str:
    """Vendor htmx locally (one-time download) for offline use; else use CDN."""
    static = WEB_DIR / "static"
    static.mkdir(exist_ok=True)
    f = static / "htmx.min.js"
    if f.exists() and f.stat().st_size > 0:
        return "/static/htmx.min.js"
    try:
        import requests
        r = requests.get(_HTMX_CDN, timeout=10)
        r.raise_for_status()
        f.write_bytes(r.content)
        return "/static/htmx.min.js"
    except Exception:
        return _HTMX_CDN


def _case_tz_label(conn, case_id) -> str:
    row = conn.execute(
        """SELECT tz_offset_minutes, tz_name FROM bundles
           WHERE case_id = ? AND tz_offset_minutes IS NOT NULL ORDER BY id LIMIT 1""",
        (case_id,)).fetchone()
    if not row:
        return "UTC?"
    return format_offset(row["tz_offset_minutes"]) + (f" {row['tz_name']}" if row["tz_name"] else "")


def _ranked_findings(conn, case_id):
    rows = conn.execute(
        """SELECT f.id, f.severity, f.confidence, f.title, f.rule_id,
                  COUNT(fe.event_id) AS evidence
           FROM findings f LEFT JOIN finding_evidence fe ON fe.finding_id = f.id
           WHERE f.case_id = ? GROUP BY f.id""", (case_id,)).fetchall()
    return sorted(rows, key=lambda r: (SEVERITY_RANK.get(r["severity"], 0),
                                       CONFIDENCE_RANK.get(r["confidence"], 0), r["evidence"]),
                  reverse=True)


def create_app() -> FastAPI:
    app = FastAPI(title="Intune RCA")
    (WEB_DIR / "static").mkdir(exist_ok=True)
    app.mount("/static", StaticFiles(directory=str(WEB_DIR / "static")), name="static")
    templates.env.globals["htmx_src"] = _ensure_htmx()

    @app.get("/", response_class=HTMLResponse)
    def index(request: Request):
        conn = db.connect()
        cases = conn.execute(
            """SELECT c.id, c.created_utc, c.status, c.symptom_text,
                      (SELECT machine_name FROM bundles b WHERE b.case_id=c.id ORDER BY b.id LIMIT 1) machine,
                      (SELECT COUNT(*) FROM findings f WHERE f.case_id=c.id) findings
               FROM cases c ORDER BY c.id DESC""").fetchall()
        return templates.TemplateResponse(request, "index.html", {"cases": cases})

    def _case_context(conn, cid: int) -> dict | None:
        case = conn.execute("SELECT * FROM cases WHERE id = ?", (cid,)).fetchone()
        if case is None:
            return None
        bundle = conn.execute(
            "SELECT * FROM bundles WHERE case_id = ? ORDER BY id LIMIT 1", (cid,)).fetchone()
        by_source = conn.execute(
            "SELECT source, COUNT(*) n FROM events WHERE case_id = ? GROUP BY source ORDER BY n DESC",
            (cid,)).fetchall()
        apps = conn.execute(
            f"""SELECT e.actor, m.display_name,
                       SUM(e.severity IN ('error','critical')) errors,
                       MAX(CASE WHEN e.event_code IS NOT NULL THEN e.event_code END) code
                FROM events e LEFT JOIN app_map m ON m.app_guid = e.actor
                WHERE e.case_id = ? AND e.actor IS NOT NULL
                      AND LENGTH(e.actor)=36 AND e.actor LIKE '{_GUID_LIKE}'
                GROUP BY e.actor HAVING errors > 0 ORDER BY errors DESC LIMIT 30""", (cid,)).fetchall()
        present = [s["source"] for s in by_source]
        known = ["IME", "evtx", "MSI", "WU"]
        sources = known + [s for s in present if s not in known]
        return {"case": case, "bundle": bundle, "by_source": by_source, "sources": sources,
                "apps": apps, "findings": _ranked_findings(conn, cid), "tz": _case_tz_label(conn, cid)}

    def _status(html: str, trigger: bool = True) -> HTMLResponse:
        """Return an action-status fragment; trigger refreshes the case-state region."""
        headers = {"HX-Trigger": "case-changed"} if trigger else {}
        return HTMLResponse(html, headers=headers)

    @app.get("/case/{cid}", response_class=HTMLResponse)
    def case_view(request: Request, cid: int):
        conn = db.connect()
        ctx = _case_context(conn, cid)
        if ctx is None:
            return HTMLResponse(f"<h2>No case {cid}</h2>", status_code=404)
        return templates.TemplateResponse(request, "case.html", {**ctx})

    @app.get("/case/{cid}/state", response_class=HTMLResponse)
    def case_state(request: Request, cid: int):
        conn = db.connect()
        ctx = _case_context(conn, cid)
        if ctx is None:
            return HTMLResponse("", status_code=404)
        return templates.TemplateResponse(request, "_case_state.html", {**ctx})

    # --- New case (from the index form) ---------------------------------------
    @app.post("/cases")
    def new_case(symptom: str = Form("")):
        conn = db.connect()
        cur = conn.execute("INSERT INTO cases (created_utc, symptom_text) VALUES (?, ?)",
                           (now_utc_iso(), symptom.strip() or "(no symptom)"))
        conn.commit()
        return Response(status_code=204, headers={"HX-Redirect": f"/case/{cur.lastrowid}"})

    @app.get("/zips")
    def discover_zips():
        """Return DiagLogs ZIPs found in common places, newest first.

        Browsers can't reveal a real file path from <input type=file> for security
        reasons, so an HTML file picker can't drive the ingest endpoint (which
        needs a server-side path). Instead we surface a datalist of ZIPs we can
        actually see on disk from a few obvious locations: the project folder,
        the user's Downloads, and an opt-in RCA_INTAKE_DIR.
        """
        import os
        seen, hits = set(), []
        dirs = [config.HOME, config.REPO_ROOT, Path.home() / "Downloads"]
        if env := os.environ.get("RCA_INTAKE_DIR"):
            dirs.insert(0, Path(env))
        for d in dirs:
            try:
                for p in d.glob("DiagLogs-*.zip"):
                    rp = str(p.resolve())
                    if rp in seen:
                        continue
                    seen.add(rp)
                    hits.append((p.stat().st_mtime, rp))
            except OSError:
                continue
        hits.sort(reverse=True)
        return {"zips": [p for _, p in hits[:30]]}

    # --- Pipeline actions (mutate state, then refresh the case-state region) ---
    @app.post("/case/{cid}/ingest", response_class=HTMLResponse)
    def act_ingest(cid: int, zip_path: str = Form("")):
        conn = db.connect()
        p = Path(zip_path.strip().strip('"'))
        if not zip_path.strip() or not p.exists():
            return _status(f"<span class='err'>ZIP not found: {zip_path}</span>", trigger=False)
        try:
            r = ingest_zip(conn, cid, p)
        except Exception as exc:
            return _status(f"<span class='err'>ingest failed: {exc}</span>", trigger=False)
        return _status(f"✓ Ingested {r['files_cataloged']} files from {p.name} "
                       f"(machine {r['machine']}, tz {format_offset(r['tz_offset'])}, "
                       f"{r['cabs_expanded']} CABs).")

    @app.post("/case/{cid}/delete")
    def act_delete(cid: int):
        """Delete a case: DB rows + the materialized raw files.

        Bulk children are deleted explicitly via their case/bundle-scoped indexes
        (events alone can be hundreds of thousands of rows); the FK cascade then
        only has the small remainder to walk.
        """
        import shutil
        conn = db.connect()
        if not conn.execute("SELECT 1 FROM cases WHERE id = ?", (cid,)).fetchone():
            return HTMLResponse("<span class='err'>No such case.</span>", status_code=404)
        conn.execute("PRAGMA foreign_keys = ON")
        conn.execute("DELETE FROM events WHERE case_id = ?", (cid,))
        conn.commit()  # release the write lock between the heavy chunks
        for table in ("registry_values", "installed_apps", "file_facts"):
            conn.execute(f"""DELETE FROM {table} WHERE bundle_id IN
                             (SELECT id FROM bundles WHERE case_id = ?)""", (cid,))
        conn.execute("DELETE FROM cases WHERE id = ?", (cid,))
        conn.commit()
        shutil.rmtree(config.case_raw_dir(cid), ignore_errors=True)
        return Response(status_code=204, headers={"HX-Redirect": "/"})

    @app.post("/case/{cid}/upload", response_class=HTMLResponse)
    def act_upload(cid: int, file: UploadFile = File(...)):
        """Browser drag-drop/Browse upload: stream to disk, then ingest as usual."""
        import shutil
        name = Path(file.filename or "").name
        if not name.lower().endswith(".zip"):
            return _status("<span class='err'>Only .zip files can be ingested.</span>", trigger=False)
        dest_dir = config.HOME / "uploads"
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest = dest_dir / name
        with dest.open("wb") as out:  # stream in chunks — packages can be 2 GB
            shutil.copyfileobj(file.file, out, length=1024 * 1024)
        conn = db.connect()
        try:
            r = ingest_zip(conn, cid, dest)
        except Exception as exc:
            return _status(f"<span class='err'>ingest failed: {exc}</span>", trigger=False)
        return _status(f"✓ Uploaded + ingested {r['files_cataloged']} files from {name} "
                       f"(machine {r['machine']}, tz {format_offset(r['tz_offset'])}, "
                       f"{r['cabs_expanded']} CABs).")

    @app.post("/case/{cid}/parse", response_class=HTMLResponse)
    def act_parse(cid: int):
        conn = db.connect()
        r = parse_case(conn, cid, categories=("all",))
        if "error" in r:
            return _status(f"<span class='err'>{r['error']}</span>", trigger=False)
        # "Parse all" also loads the registry exports — the CLI-only path was the
        # reason every web-parsed case had no inventory/registry (cases 19/24/25).
        from rca.regload import load_registry_case
        reg = load_registry_case(conn, cid, reparse=False)
        return _status(f"✓ Parsed {r['artifacts_parsed']} artifact(s) → {r['events']} events "
                       f"({', '.join(f'{k}:{v}' for k, v in r['by_source'].items())}); "
                       f"registry {reg['values']} values, {reg['apps']} apps.")

    @app.post("/case/{cid}/etl", response_class=HTMLResponse)
    def act_etl(cid: int):
        conn = db.connect()
        r = load_wu(conn, cid)
        if r["note"]:
            return _status(f"<span class='err'>{r['note']}</span>", trigger=False)
        if r["etl_files"] == 0:
            n = conn.execute("SELECT COUNT(*) FROM events WHERE case_id=? AND source='WU'",
                             (cid,)).fetchone()[0]
            return _status(f"Nothing new to decode — {n} WU events already in the timeline "
                           f"(search source=WU below). Only WindowsUpdate ETLs decode; USO/WPP "
                           f"traces are undecodable and skipped.", trigger=False)
        return _status(f"✓ Decoded {r['etl_files']} ETL(s) → {r['events']} WU events.")

    @app.post("/case/{cid}/analyze", response_class=HTMLResponse)
    def act_analyze(cid: int):
        conn = db.connect()
        r = analyze_case(conn, cid)
        return _status(f"✓ Analyzed: {r['findings']} finding(s), {r['evidence']} evidence link(s).")

    @app.post("/case/{cid}/resolve", response_class=HTMLResponse)
    def act_resolve(cid: int):
        conn = db.connect()
        try:
            interactive = graph.auth_mode() != "app-only"
            r = resolver.resolve_case(conn, cid, errors_only=True, interactive=interactive)
        except graph.GraphNotConfigured as exc:
            return _status(f"<span class='err'>Graph not available: {exc}</span>", trigger=False)
        return _status(f"✓ Resolved {r['resolved']} app name(s) (cached {r['cached']}, "
                       f"not-found {r['not_found']}).")

    @app.post("/case/{cid}/detection", response_class=HTMLResponse)
    def act_detection(cid: int):
        conn = db.connect()
        try:
            interactive = graph.auth_mode() != "app-only"
            r = detection.fetch_case(conn, cid, errors_only=True, interactive=interactive)
        except graph.GraphNotConfigured as exc:
            return _status(f"<span class='err'>Graph not available: {exc}</span>", trigger=False)
        return _status(f"✓ Detection rules: fetched {r['fetched']} (cached {r['cached']}, "
                       f"not-found {r['not_found']}).")

    # --- Rules (no-code authoring) -------------------------------------------
    @app.get("/rules", response_class=HTMLResponse)
    def rules_page(request: Request):
        conn = db.connect()
        builtins = [{"name": fn.__name__, "source": src} for fn, src in load_rules()]
        user_rules = conn.execute("SELECT * FROM user_rules ORDER BY id DESC").fetchall()
        return templates.TemplateResponse(request, "rules.html", {
            "builtins": builtins, "user_rules": user_rules})

    @app.post("/rules")
    def rules_create(
        name: str = Form(...), title: str = Form(""),
        match_source: str = Form(""), match_code: str = Form(""),
        match_contains: str = Form(""), match_severity: str = Form(""),
        group_by_actor: str = Form(""), min_count: int = Form(1),
        severity: str = Form("warn"), confidence: str = Form("medium"),
        recommendation: str = Form(""),
    ):
        conn = db.connect()
        name = name.strip()
        if not name:
            return HTMLResponse("<span class='err'>Name is required.</span>")
        conn.execute(
            """INSERT INTO user_rules
               (name, enabled, match_source, match_code, match_contains, match_severity,
                group_by_actor, min_count, severity, confidence, title, recommendation, created_utc)
               VALUES (?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (name, match_source or None, match_code.strip() or None,
             match_contains.strip() or None, match_severity or None,
             1 if group_by_actor else 0, max(1, min_count), severity, confidence,
             title.strip() or name, recommendation.strip() or None, now_utc_iso()))
        conn.commit()
        return Response(status_code=204, headers={"HX-Refresh": "true"})

    @app.post("/rules/{rid}/toggle")
    def rules_toggle(rid: int):
        conn = db.connect()
        conn.execute("UPDATE user_rules SET enabled = 1 - enabled WHERE id = ?", (rid,))
        conn.commit()
        return Response(status_code=204, headers={"HX-Refresh": "true"})

    @app.post("/rules/{rid}/delete")
    def rules_delete(rid: int):
        conn = db.connect()
        conn.execute("DELETE FROM user_rules WHERE id = ?", (rid,))
        conn.commit()
        return Response(status_code=204, headers={"HX-Refresh": "true"})

    @app.get("/errorcodes", response_class=HTMLResponse)
    def errorcodes_page(request: Request):
        data = errormap.load()
        codes = [{"code": k, **v} for k, v in sorted(data.items())]
        return templates.TemplateResponse(request, "errorcodes.html",
                                          {"codes": codes, "path": str(errormap.config.ERROR_MAP_PATH),
                                           "hunter_n": errormap.hunter_count()})

    @app.post("/errorcodes/fetch-hunter", response_class=HTMLResponse)
    def errorcodes_fetch_hunter():
        try:
            errormap.fetch_hunter()
        except Exception as exc:
            return HTMLResponse(f"<span class='err'>Fetch failed: {exc}</span>")
        return Response(status_code=204, headers={"HX-Refresh": "true"})

    @app.post("/case/{cid}/profiles", response_class=HTMLResponse)
    def act_profiles(cid: int, refresh: str = Form("")):
        from rca.enrich import profiles as prof
        conn = db.connect()
        try:
            r = prof.fetch_profile_states(conn, cid, refresh=bool(refresh))
        except Exception as exc:
            return _status(f"<span class='err'>profiles failed: {exc}</span>", trigger=False)
        if "error" in r:
            return _status(f"<span class='err'>{r['error']}</span>", trigger=False)
        failing = (" Failing: " + "; ".join(r["failing"])) if r["failing"] else " All healthy."
        return _status(f"✓ {r['profiles']} configuration profile(s) from Graph "
                       f"({'refetched' if r['fetched'] else 'cached'}).{failing} "
                       f"See `rca profiles -c {cid}` for the full table.")

    @app.get("/case/{cid}/report")
    def report_download(cid: int, format: str = "html", redact: str = "1"):
        conn = db.connect()
        do_redact = redact != "0"   # default redacted; only "0" opts out
        if format == "md":
            content, ext, mt = render_markdown(conn, cid, redact=do_redact), "md", "text/markdown"
        else:
            content, ext, mt = render_html(conn, cid, redact=do_redact), "html", "text/html"
        if content is None:
            return HTMLResponse(f"<h2>No case {cid}</h2>", status_code=404)
        return Response(content, media_type=mt, headers={
            "Content-Disposition": f'attachment; filename="case-{cid}-report.{ext}"'})

    @app.get("/case/{cid}/finding/{fid}", response_class=HTMLResponse)
    def finding_detail(request: Request, cid: int, fid: int):
        conn = db.connect()
        f = conn.execute("SELECT * FROM findings WHERE id=? AND case_id=?", (fid, cid)).fetchone()
        if f is None:
            return HTMLResponse("<p>not found</p>", status_code=404)
        ev = conn.execute(
            """SELECT e.ts_local, e.ts_utc, e.source, e.event_code, e.actor, e.message
               FROM finding_evidence fe JOIN events e ON e.id = fe.event_id
               WHERE fe.finding_id = ? ORDER BY e.ts_utc LIMIT 12""", (fid,)).fetchall()
        return templates.TemplateResponse(request, "_finding_detail.html", {"f": f, "ev": ev})

    @app.post("/case/{cid}/timeline", response_class=HTMLResponse)
    def timeline_frag(request: Request, cid: int,
                      q: str = Form(""), source: str = Form(""), severity: str = Form("")):
        conn = db.connect()
        params: list = [cid]
        if q.strip():
            sql = ("""SELECT e.ts_local, e.ts_utc, e.source, e.severity, e.event_code, e.actor, e.message
                      FROM events_fts fts JOIN events e ON e.id = fts.rowid
                      WHERE fts.events_fts MATCH ? AND e.case_id = ?""")
            params = [q.strip(), cid]
            if source:
                sql += " AND e.source = ?"; params.append(source)
            if severity:
                sql += " AND e.severity = ?"; params.append(severity)
            sql += " ORDER BY e.ts_utc LIMIT 60"
        else:
            sql = ("""SELECT ts_local, ts_utc, source, severity, event_code, actor, message
                      FROM events WHERE case_id = ?""")
            if source:
                sql += " AND source = ?"; params.append(source)
            if severity:
                sql += " AND severity = ?"; params.append(severity)
            sql += " ORDER BY ts_utc IS NULL, ts_utc LIMIT 60"
        try:
            rows = conn.execute(sql, params).fetchall()
        except Exception as exc:
            return HTMLResponse(f"<p class='err'>query error: {exc}</p>")
        return templates.TemplateResponse(request, "_timeline.html", {"rows": rows})

    @app.post("/case/{cid}/investigate", response_class=HTMLResponse)
    def investigate_frag(request: Request, cid: int, model: str = Form("")):
        conn = db.connect()
        try:
            provider = agent_llm.get_provider(model=model.strip() or None)
            provider.ping()
            result = run_investigation(conn, cid, provider)
        except agent_llm.LLMError as exc:
            return HTMLResponse(f"<p class='err'>LLM not ready: {exc}</p>")
        return templates.TemplateResponse(request, "_report.html", {
            "report": result["report"], "steps": result["steps"],
            "trace": result["trace"], "model": provider.label})

    return app
