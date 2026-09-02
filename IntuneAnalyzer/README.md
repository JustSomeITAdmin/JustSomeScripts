# Intune RCA

Local-first root-cause analysis for **Intune "Collect diagnostics" packages**.
Drop in the ZIP, get ranked, evidence-cited findings. No cloud, no paid
services — Python + PowerShell + SQLite on your own machine.

## Quick start (web UI)

```powershell
py -m venv .venv
.\.venv\Scripts\python.exe -m pip install -e .
.\.venv\Scripts\rca.exe web        # serves http://127.0.0.1:8000 and opens a browser
```

Then, in the browser:

1. **New case** — one line describing the symptom (for you, not the analysis).
2. **Ingest** — pick the `DiagLogs-*.zip`; the path field auto-suggests ZIPs found
   in the project folder, `Downloads`, and `RCA_INTAKE_DIR` (if set).
3. **Parse all** → **Analyze** — findings appear ranked, each with click-to-expand
   evidence pointing at the exact log lines that prove it.

That's the whole loop for most cases. Everything below is optional depth.

## The web UI

`rca web` serves a local FastAPI + HTMX app (localhost only, no auth) — the
**full pipeline in the browser**, so a tech never needs the terminal:

- **Pipeline buttons** — Ingest, Parse all, Decode WU ETL, Analyze, Resolve
  names (Graph), Detection rules (Graph). Each runs the same code as the CLI
  and auto-refreshes the case view.
- **Case view** — machine, device timezone, event counts, ranked findings with
  evidence, failing-apps rollup, and full-text **timeline search** across every
  parsed source (times shown device-local).
- **Rules page (`/rules`)** — author **no-code rules**: match by source / event
  code / message substring / severity → emit a finding. No Python, no SQL.
  Recommendations auto-fill from the error-code map. Toggle/delete inline;
  built-in and drop-in Python rules are listed read-only.
- **Error codes (`/errorcodes`)** — the plain-English error map (Intune / AppX /
  Windows / MSI / WU). Backed by `error_codes.json`; edit the JSON to add or
  correct codes — no reinstall.
- **Download report** — one-file HTML or Markdown RCA summary, **redacted by
  default** (UPNs, hostnames, SIDs, user paths, tenant collection id scrubbed;
  app names, detection rules, and error codes kept — that's the actionable
  content). The database itself is never redacted; only exports.
- **Agent investigation** — a local LLM (Ollama) writes a root-cause report by
  querying the case DB through read-only tools. Optional; needs Ollama + a model
  (`ollama pull qwen2.5:7b`).

HTMX is vendored on first run, so the UI works offline.

## Rules: how findings happen

Three tiers, all run by **Analyze**:

- **Built-in** (`rca/rules.py`) — Win32 app failures (code-aware), MSI failures,
  non-zero detection/remediation scripts, AppX/MSIX errors, collection gaps.
- **No-code** (web `/rules`) — the common "flag when X appears" case, authorable
  by any tech.
- **Drop-in Python** (`custom_rules/*.py`) — cross-source correlation. Shipped
  examples pay rent: BitLocker recovery correlated to Secure Boot CA updates,
  the ESP user-sync wedge ("enrolled but nothing installs until reboot"), IME
  token-failure clusters. Each grew out of a real case; add yours the same way.

Every finding cites its evidence events, so "trust me" is never the answer.

## CLI

Same engine, scriptable. Activate once per terminal
(`.\.venv\Scripts\Activate.ps1`) or prefix `.\.venv\Scripts\`.

```powershell
rca new-case -s "Win32 app installs failing on PC01 after June servicing"
rca ingest  -c 1 -z "DiagLogs-PC01-20260101T120000Z.zip"
rca parse    -c 1 --category all            # everything with a parser
rca analyze  -c 1                           # run rules
rca findings -c 1                           # ranked findings
rca finding  -c 1 -i 2                      # one finding: summary, fix, evidence

# timeline + search
rca summary  -c 1
rca timeline -c 1 --severity error          # chronological (device-local by default)
rca timeline -c 1 --actor 75d62725          # one app's story across check-ins
rca search   -c 1 "not detected"            # full-text search (FTS5)
rca apps     -c 1 --errors-only             # per-app outcome rollup (IME)

# registry state (queried, not timeline)
rca parse     -c 1 --category registry
rca inventory -c 1 --contains 7-Zip         # installed-app inventory (Uninstall keys)
rca regquery  -c 1 --key SCHANNEL           # raw registry values

# optional depth
rca etl       -c 1                          # decode WindowsUpdate ETLs -> WU events
rca resolve   -c 1                          # app GUIDs -> names via Graph (cached)
rca detection -c 1                          # fetch + verify Win32 detection rules
rca collect-script -c 1                     # generate a device collector for missing targets
rca supplemental   -c 1 -f out.json         # ingest collector output -> re-evaluate
rca investigate -c 1                        # local LLM agent writes an RCA report
rca report      -c 1 --format html          # shareable report (redacted by default)
rca rules                                   # list built-in / custom / no-code rules
rca tz -c 1                                 # show/auto-detect device timezone
```

## Install (Windows)

Clone the repo and run the installer — it finds Python, creates a venv beside
the checkout (`rca-venv`), installs the tool in editable mode, and prints how
to run it. Data (`data\cases.db` + materialized files) and your `custom_rules`
stay in this folder; both are gitignored.

```powershell
git clone https://github.com/JustSomeITAdmin/JustSomeScripts.git
cd JustSomeScripts\IntuneAnalyzer
powershell -ExecutionPolicy Bypass -File .\install.ps1
.
ca-venv\Scripts
ca.exe web
```

Requirements: **Windows** (parsers use `Get-WinEvent`, `expand.exe`,
`Get-WindowsUpdateLog`), **Python 3.11+**, and optionally **Ollama** + a model
for the LLM agent. To install from a built wheel instead
(`python -m build --wheel`), put the `.whl` next to `install.ps1`; data then
lives under `%USERPROFILE%\.intune-rca` (override with `RCA_HOME`).

Graph features (app-name resolution, detection-rule fetch, profile states,
remediation names) sign you in interactively with Microsoft's well-known
public client — no app registration needed; `.env.example` shows the optional
app-only setup. Nothing leaves your machine otherwise.

**Collecting logs without the Intune portal:** `Collect-IntuneDiag.ps1` builds
a diagnostics ZIP in the same layout Intune's "Collect diagnostics" produces,
plus a few channels/keys Intune skips (Audio capture sessions, local group
membership, Secure Boot servicing state, scheduled tasks). Run it as SYSTEM or
admin on the device, then ingest the ZIP like any other.

> PowerShell note: run executables with a leading `.\` and backslashes
> (`.\.venv\Scripts\rca.exe`), not forward slashes.

## Under the hood

```
Web UI (FastAPI + HTMX) / CLI (Typer)
        →  Ingest → Parsers → Unified timeline → Rule engine → Enrichment
                        │                │             │            │
                        ▼                ▼             ▼            ▼
                  SQLite catalog + events timeline (FTS5) + findings
```

**Ingest & catalog** — the package is *self-describing*: every top-level ZIP
entry is named `(N) <CollectorType> <descriptor>`, with `No Results - Error`
on failed collections, plus a `results.xml` manifest. Ingest reads all of that
into SQLite so a 200 MB–2 GB package becomes queryable **without extracting it
to disk** (entries are stream-hashed in place). Only nested CABs
(`MpSupportFiles.cab`, `mdmlogs-*.cab`) are materialized, expanded with
`expand.exe`, and cataloged as child artifacts.

**IME parser** — CMTrace-format engine logs (`IntuneManagementExtension.log`,
`AppWorkload.log`, `AgentExecutor.log`, …): app ids extracted by context,
error/exit codes, per-app `ReportingState` outcome JSON (HRESULTs as
`0xXXXXXXXX`).

**evtx parser** — `.evtx` is materialized and read by `Get-WinEvent` via
`rca/ps/read_evtx.ps1` (default: Critical/Error/Warning): true UTC timestamps,
rendered messages, providers.

**MSI parser** — per-app `*.msi.log` verbose logs (UTF-16). Selective: install
start, hard failures (Return value 3, failed custom actions), authoritative
result code (0/1603/1618/3010…). An MSI returning 0 while IME reports
`0x87D1041C` (not detected) isolates the fault to the **detection rule**.

**Registry parser** — collected `.reg` exports (UTF-16) → `registry_values` +
an `installed_apps` inventory from Uninstall keys. State, not timeline; queried
via `inventory` / `regquery` and by the detection evaluator.

**WU ETL (on demand)** — ETW traces are binary and expensive, so decoding is
opt-in: `Get-WindowsUpdateLog` merges the `.etl`s, then warn/error lines load
as `source='WU'` events. Built for "after the update" symptoms.

**Timezone normalization** — device UTC offset auto-detected at ingest
(battery/energy report `ReportUtcOffset`, msinfo32 fallback). Every event
stores canonical `ts_utc` (sorting/correlation) **and** device-local
`ts_local` (display), so a tech reads real wall-clock. `--utc` flips; `rca tz`
redetects. A fixed offset is correct for any window not crossing a DST
boundary — essentially all RCA windows.

**Graph enrichment (optional)** — app GUID → display name
(`/deviceAppManagement/mobileApps`, cached across cases), and a
**detection-rule evaluator** that fetches a failing app's Win32 detection
rules and checks them against the parsed registry/inventory. Auth is
interactive browser (well-known public client — no app registration),
device-code, or app-only. For targets the package doesn't include,
`collect-script` generates a device collector whose JSON output
(`supplemental`) flips verdicts from `unknown` to definitive.

**LLM agent (optional, local)** — `investigate` drives a tool-using model to a
written RCA report. Read-only and provider-agnostic (default Ollama — free,
private). The agent never ingests raw logs; it calls bounded DB tools
(`case_overview`, `list_findings`, `search_events`, `timeline`, `regquery`,
`detection_for_app`, …), so even a 7B model handles a 2 GB package on modest
hardware. Configure via `RCA_LLM_PROVIDER`, `RCA_OLLAMA_MODEL`.

## Layout

```
rca/
  cli.py            Typer commands
  config.py         paths (data dir, per-case raw store)
  db.py             SQLite connection + migration runner (PRAGMA user_version)
  schema.py         schema as ordered migrations
  util.py           hashing, HRESULT/size formatting
  models.py         Event dataclass (the normalized record shape)
  parsing.py        run parsers over artifacts -> events (normalizes timestamps)
  timeutil.py       UTC <-> device-local conversion
  ingest/
    classify.py     decode "(N) <CollectorType> ..." names + categorize files
    manifest.py     parse results.xml
    cabs.py         expand nested CABs via expand.exe
    tzinfo.py       detect device UTC offset (battery report / msinfo32)
    ingest.py       catalog ZIP -> DB, materialize + expand CABs, detect tz
  parsers/
    cmtrace.py      CMTrace record reader (shared)
    ime.py          IME semantics: app ids, codes, ReportingState JSON
    msi.py          Windows Installer verbose logs (UTF-16, selective)
    registry.py     .reg export parser (UTF-16, key/value blocks)
    evtx.py         .evtx via PowerShell (file parser)
    wulog.py        WindowsUpdate.log parser (selective: warn/error)
  regload.py        load .reg -> registry_values + installed_apps
  supplemental.py   generate device collector + ingest its JSON
  etl.py            on-demand WindowsUpdate ETL decode -> WU events
  rules.py          built-in rule pack (each rule -> evidence-cited Findings)
  ruleset.py        @rule registry + custom_rules/ loader
  userrules.py      compile no-code rules (user_rules table) -> rule callables
  errormap.py       editable code -> plain-English meaning
  engine.py         run built-in + custom + no-code rules -> findings
  redact.py         scrub PII (UPN/host/SID/paths) for shareable output
  report.py         export a case as redacted HTML / Markdown
  agent/
    llm.py          provider-agnostic chat-with-tools (Ollama)
    tools.py        read-only DB tools the agent may call
    investigator.py the investigation loop -> RCA report
  enrich/
    graph.py        Microsoft Graph client (interactive / device-code / app-only)
    resolver.py     resolve case app GUIDs -> app_map (cached)
    detection.py    fetch + evaluate Win32 detection rules vs device data
  web/
    app.py          FastAPI app (routes + HTMX fragments)
    templates/      Jinja2 pages + fragments
    static/         app.css + vendored htmx.min.js
  ps/
    read_evtx.ps1       Get-WinEvent -> JSON worker
    convert_wu_etl.ps1  Get-WindowsUpdateLog: ETL -> merged log
custom_rules/       drop-in Python rules (loaded at analyze time)
data/               cases.db + per-case materialized files (gitignored)
```

## Data model (core tables)

`cases` → `bundles` → `artifacts` (the catalog). `events` is the unified
timeline, kept searchable by `events_fts`. `findings` / `finding_evidence`
hold RCA output. `user_rules` holds no-code rules. `app_map` / `error_map` /
`app_detection` are enrichment caches that persist across cases.

## License

MIT — see [LICENSE](LICENSE).
