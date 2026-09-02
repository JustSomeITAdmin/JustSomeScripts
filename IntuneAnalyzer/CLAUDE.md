# CLAUDE.md — working on Intune RCA with an LLM

This file is for AI coding assistants (Claude Code, Copilot, Cursor, a local
model — whatever you use). It explains how the project is shaped, the
conventions that keep it working, and how to verify a change. Humans: read
`README.md` first; this is the "how to change it safely" companion.

## What this is

A local-first root-cause-analysis tool for Intune **"Collect diagnostics"**
ZIPs. Pipeline: `ingest` (catalog the ZIP into SQLite without extracting) →
`parse` (IME CMTrace logs, `.evtx` via PowerShell, MSI logs, `.reg` exports,
optional WU ETL) → a unified `events` timeline → `analyze` (rules emit
evidence-cited `findings`) → optional Graph enrichment and a local LLM agent.
Web UI (FastAPI + HTMX) and CLI (Typer) run the same code.

Everything runs on the operator's machine. **No telemetry, no cloud calls**
except explicit Graph enrichment the user triggers.

## Layout (where to change what)

| You want to… | Edit |
|---|---|
| Teach the tool a new error code's meaning | `error_codes.json` (no code) |
| Add a signature-style finding | new file in `custom_rules/` (loaded by path at analyze time — no reinstall) |
| Change a built-in rule | `rca/rules.py` |
| Parse a new log type | `rca/parsers/<name>.py` + route it in `rca/parsing.py` (+ `rca/ingest/classify.py` if the ZIP entry needs a category) |
| Add a CLI command | `rca/cli.py` (Typer; reuse `_render_events`, `_require_case`, `_short`) |
| Add a web action/page | `rca/web/app.py` + `rca/web/templates/` (HTMX fragments return HTML + `HX-Trigger: case-changed`) |
| Change the schema | append a new migration string to `MIGRATIONS` in `rca/schema.py` — **never edit an existing one** (tracked by `PRAGMA user_version`) |
| Graph calls | `rca/enrich/graph.py` (token helpers already handle interactive / device-code / app-only) |
| Collect more from a device | `Collect-IntuneDiag.ps1` (mirrors Intune's ZIP layout; keep new entries in the same `(N) <CollectorType> ...` naming so ingest classifies them) |

## Conventions that matter

- **Timestamps:** every event stores `ts_utc` (canonical, sort key) and
  `ts_local` (device wall clock). Query/compare with plain ISO strings using
  `T` (e.g. `'2026-09-02T11:50'`) — SQLite's `datetime()` emits a space and
  breaks string comparison against stored values. IME logs written during
  OOBE can be hours off (device clock still on the image default) while
  `.evtx` timestamps are true UTC; note it when correlating.
- **Event identity:** event ids collide across providers (Winlogon 7001/7002
  vs HelloForBusiness 7001/7002; Kernel-General 16 vs everything). In rules,
  qualify by provider: `rca.ruleset.events_of(conn, case_id, "HelloForBusiness", "7002")`.
  A bare `LIKE '%WER%'` matches `Kernel-PoWER` — be specific.
- **IME service-start replays:** after IME restarts it re-logs every app's
  cached prior state ("...reporting state initialized"). Those are not fresh
  events; rules must exclude them (see `rule_win32_app_failures`).
- **Evidence or it didn't happen:** every `Finding` carries
  `evidence_event_ids`. A rule that can't point at rows should return `[]`.
  Prefer an evidence *hierarchy* (explicit event beats inference beats a
  script's status report) — the BitLocker rule is the reference pattern.
- **Confidence is honest:** `high` only when an explicit event proves it;
  `medium` for inference; say "not identified" rather than guessing.
- **Level filtering:** `.evtx` are parsed at Critical/Error/Warning by
  default; channels whose *info* events carry verdicts (System, TPM,
  BitLocker Management) are listed in `_ALL_LEVEL_CHANNELS` in
  `rca/parsers/evtx.py`. If a rule needs an info-level event from another
  channel, add the channel there — and remember old cases must be re-parsed
  (`rca parse -c N --category eventlog --reparse`) before you judge the rule
  against them.
- **PowerShell workers** (`rca/ps/*.ps1`) must stay PowerShell 5.1 compatible
  and pure ASCII. Array parameters don't bind through `-File`; pass
  comma-joined strings and split in-script.
- **Redaction:** the DB is never redacted; only exports (`rca report`) are.
  Don't commit anything from `data/` — it holds parsed logs (UPNs, hostnames)
  and the Graph token cache.

## Verifying a change

There is no big test suite; the tool is validated against real cases. The
loop that works:

```powershell
.\rca-venv\Scripts\rca.exe run -s "symptom" -z .\DiagLogs-HOST-....zip   # new case, full pipeline
.\rca-venv\Scripts\rca.exe findings -c N
.\rca-venv\Scripts\rca.exe analyze -c N          # after editing a rule: re-run rules only
.\rca-venv\Scripts\rca.exe rules                 # confirms every rule file still loads
```

Investigation primitives (use these before writing ad-hoc SQL):
`rca boots` (boot/shutdown/restart-initiator/recovery chain), `rca window
--from --to` (everything in a time span), `rca hs --resolve` (proactive
remediation runs + names/assignments from Graph), `rca app <guid>` (one app's
story), `rca timeline`, `rca search`, `rca regquery`, `rca inventory`.

When you add a rule: run it against a case where it *should* fire and at
least one where it should not, and include both in your notes. When you
change a rule's verdict text, re-run every case that rule touches.

## Things not to do

- Don't add cloud/paid dependencies to the core path. Graph and the LLM are
  optional and opt-in; keep them that way.
- Don't put organisation-specific names (groups, hostnames, policy GUIDs,
  people) in rule text. Describe the *pattern* and the generic fix; put the
  specifics in your own private notes.
- Don't widen a rule's match to make it fire — narrow the evidence instead.
- Don't edit an existing migration; append.
- Don't read a 2 GB ZIP into memory; `ingest` streams entries for a reason.
