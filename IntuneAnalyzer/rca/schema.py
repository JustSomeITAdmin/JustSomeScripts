"""Database schema as an ordered list of migrations.

Migrations are applied in order and tracked via `PRAGMA user_version` — no
external migration framework needed. To evolve the schema, append a new SQL
string to MIGRATIONS; never edit an existing one.

The full core schema lands in migration 1 even though Phase 0 only populates
`cases`, `bundles`, and `artifacts`. Defining `events`/`findings` now means
later phases add rows, not tables.
"""

from __future__ import annotations

MIGRATIONS: list[str] = [
    # --- Migration 1: core schema --------------------------------------------
    """
    -- One investigation: a symptom + one or more evidence bundles.
    CREATE TABLE cases (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        created_utc  TEXT NOT NULL,
        symptom_text TEXT,
        status       TEXT NOT NULL DEFAULT 'open',   -- open | analyzed | closed
        notes        TEXT
    );

    -- An evidence package attached to a case (an Intune diagnostics ZIP today;
    -- later also Defender exports or supplemental script output).
    CREATE TABLE bundles (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        case_id       INTEGER NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
        kind          TEXT NOT NULL DEFAULT 'intune_diag',
        source_path   TEXT NOT NULL,        -- original ZIP path
        sha256        TEXT,                 -- hash of the ZIP itself
        machine_name  TEXT,                 -- parsed from the ZIP filename
        collected_utc TEXT,                 -- parsed from the ZIP filename
        collection_id TEXT,                 -- Collection ID from results.xml
        collection_hresult INTEGER,         -- top-level HRESULT from results.xml
        ingested_utc  TEXT NOT NULL
    );

    -- The file catalog: one row per file, built cheaply at ingest by streaming
    -- the ZIP. Files inside nested CABs reference their CAB via parent_artifact_id.
    CREATE TABLE artifacts (
        id                 INTEGER PRIMARY KEY AUTOINCREMENT,
        bundle_id          INTEGER NOT NULL REFERENCES bundles(id) ON DELETE CASCADE,
        parent_artifact_id INTEGER REFERENCES artifacts(id) ON DELETE CASCADE,
        rel_path           TEXT NOT NULL,   -- path within the ZIP (or "cab!/inner")
        top_index          INTEGER,         -- the (N) index from the entry name
        collector_type     TEXT,            -- RegistryKey|Command|Events|FoldersFiles|manifest
        collection_status  TEXT,            -- ok | error
        collection_hresult INTEGER,         -- per-item HRESULT when collection failed
        category           TEXT,            -- semantic class (ime_log, defender, etl, ...)
        ext                TEXT,
        size               INTEGER,
        sha256             TEXT,
        mtime_utc          TEXT,
        materialized       INTEGER NOT NULL DEFAULT 0,  -- 1 if bytes written to disk
        raw_path           TEXT,            -- on-disk path when materialized
        parsed_status      TEXT NOT NULL DEFAULT 'pending', -- pending|parsed|skipped|error
        parser_name        TEXT
    );
    CREATE INDEX idx_artifacts_bundle   ON artifacts(bundle_id);
    CREATE INDEX idx_artifacts_category ON artifacts(category);
    CREATE INDEX idx_artifacts_status   ON artifacts(collection_status);

    -- The unified timeline: every parser normalizes into this one shape so a
    -- Defender threat, an IME error, and an evtx record sit on one axis.
    -- Populated starting in Phase 1.
    CREATE TABLE events (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        case_id     INTEGER NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
        bundle_id   INTEGER REFERENCES bundles(id) ON DELETE CASCADE,
        artifact_id INTEGER REFERENCES artifacts(id) ON DELETE SET NULL,
        ts_utc      TEXT,                   -- normalized timestamp (nullable)
        source      TEXT NOT NULL,          -- IME|Defender|evtx|CBS|MDM|WU|...
        severity    TEXT,                   -- info|warn|error|critical
        event_code  TEXT,                   -- event ID / HRESULT / exit code
        actor       TEXT,                   -- app GUID, service, user, process
        message     TEXT,
        raw_ref     TEXT                    -- back-pointer (line / byte offset)
    );
    CREATE INDEX idx_events_case   ON events(case_id);
    CREATE INDEX idx_events_ts     ON events(ts_utc);
    CREATE INDEX idx_events_source ON events(source);

    -- Full-text search over event messages (external-content FTS5 kept in sync
    -- by triggers). Lets you grep across every source in milliseconds.
    CREATE VIRTUAL TABLE events_fts USING fts5(
        message,
        content='events',
        content_rowid='id'
    );
    CREATE TRIGGER events_ai AFTER INSERT ON events BEGIN
        INSERT INTO events_fts(rowid, message) VALUES (new.id, new.message);
    END;
    CREATE TRIGGER events_ad AFTER DELETE ON events BEGIN
        INSERT INTO events_fts(events_fts, rowid, message) VALUES('delete', old.id, old.message);
    END;
    CREATE TRIGGER events_au AFTER UPDATE ON events BEGIN
        INSERT INTO events_fts(events_fts, rowid, message) VALUES('delete', old.id, old.message);
        INSERT INTO events_fts(rowid, message) VALUES (new.id, new.message);
    END;

    -- Enrichment caches (persist across cases). Populated in Phase 3.
    CREATE TABLE app_map (
        app_guid     TEXT PRIMARY KEY,
        display_name TEXT,
        publisher    TEXT,
        app_type     TEXT,
        source       TEXT,                  -- graph | registry | manual
        fetched_utc  TEXT
    );
    CREATE TABLE error_map (
        code          TEXT PRIMARY KEY,     -- e.g. 0x80070643
        family        TEXT,                 -- HRESULT | Win32 | MSI | WU
        meaning       TEXT,
        common_causes TEXT
    );

    -- Output of the RCA engine (rules in Phase 2, LLM agent in Phase 4).
    CREATE TABLE findings (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        case_id        INTEGER NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
        rule_id        TEXT,                -- rule id, or 'llm' for agent findings
        title          TEXT NOT NULL,
        confidence     TEXT,                -- low | medium | high
        severity       TEXT,
        summary        TEXT,
        recommendation TEXT,
        created_utc    TEXT NOT NULL
    );
    CREATE TABLE finding_evidence (
        finding_id INTEGER NOT NULL REFERENCES findings(id) ON DELETE CASCADE,
        event_id   INTEGER NOT NULL REFERENCES events(id) ON DELETE CASCADE,
        weight     REAL NOT NULL DEFAULT 1.0,
        PRIMARY KEY (finding_id, event_id)
    );
    """,
    # --- Migration 2: device timezone + dual-clock events -----------------------
    """
    -- The diagnosed device's UTC offset, discovered at ingest. Used to map IME
    -- device-local timestamps onto the canonical UTC axis and back for display.
    ALTER TABLE bundles ADD COLUMN tz_offset_minutes INTEGER;
    ALTER TABLE bundles ADD COLUMN tz_name TEXT;
    ALTER TABLE bundles ADD COLUMN tz_source TEXT;

    -- Device-local rendering of each event (ts_utc stays the canonical clock).
    ALTER TABLE events ADD COLUMN ts_local TEXT;
    """,
    # --- Migration 3: registry state (point-in-time, not timeline) --------------
    """
    -- Every value from the collected .reg exports. Lets us verify a detection
    -- rule that checks "does key/value X exist / equal Y?".
    CREATE TABLE registry_values (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        bundle_id   INTEGER NOT NULL REFERENCES bundles(id) ON DELETE CASCADE,
        artifact_id INTEGER REFERENCES artifacts(id) ON DELETE CASCADE,
        hive        TEXT,
        key_path    TEXT NOT NULL,
        value_name  TEXT,            -- NULL marks key presence (no value)
        value_type  TEXT,            -- sz | dword | binary | expand_sz | multi_sz | qword | key
        value_data  TEXT
    );
    CREATE INDEX idx_regval_bundle ON registry_values(bundle_id);
    CREATE INDEX idx_regval_key    ON registry_values(key_path);
    CREATE INDEX idx_regval_name   ON registry_values(value_name);

    -- Installed-app inventory derived from the Uninstall keys (what MSI/registry
    -- detection rules actually check).
    CREATE TABLE installed_apps (
        id               INTEGER PRIMARY KEY AUTOINCREMENT,
        bundle_id        INTEGER NOT NULL REFERENCES bundles(id) ON DELETE CASCADE,
        artifact_id      INTEGER REFERENCES artifacts(id) ON DELETE CASCADE,
        scope            TEXT,        -- HKLM | HKLM-WOW6432 | HKCU
        key_name         TEXT,        -- subkey (often the MSI ProductCode GUID)
        display_name     TEXT,
        display_version  TEXT,
        publisher        TEXT,
        install_date     TEXT,
        uninstall_string TEXT,
        system_component INTEGER
    );
    CREATE INDEX idx_instapp_bundle ON installed_apps(bundle_id);
    CREATE INDEX idx_instapp_name   ON installed_apps(display_name);
    """,
    # --- Migration 4: cached Win32 app detection rules (from Graph) -------------
    """
    -- Normalized detection rules per app, fetched from Graph. Cached across
    -- cases; the device-specific verdict is computed live against registry data.
    CREATE TABLE app_detection (
        app_guid       TEXT PRIMARY KEY,
        app_odata_type TEXT,
        rules_json     TEXT,         -- JSON list of normalized detection rules
        fetched_utc    TEXT
    );
    """,
    # --- Migration 5: supplemental file facts -----------------------------------
    """
    -- File presence/version facts from a supplemental collection script. Lets
    -- file-based detection rules be evaluated (otherwise 'unknown' offline).
    -- Supplemental registry data reuses registry_values (value_type 'absent' /
    -- 'key-absent' records an explicit "checked, not present").
    CREATE TABLE file_facts (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        bundle_id   INTEGER NOT NULL REFERENCES bundles(id) ON DELETE CASCADE,
        path        TEXT NOT NULL,
        present     INTEGER NOT NULL,
        version     TEXT,
        size        INTEGER,
        modified_utc TEXT
    );
    CREATE INDEX idx_filefacts_bundle ON file_facts(bundle_id);
    """,
    # --- Migration 6: no-code (declarative) rules, authorable from the web UI -----
    """
    -- A rule any tech can write without Python: match events by source / code /
    -- message substring / severity, then emit a finding. Cross-source correlation
    -- still lives in Python rules; this covers the common "flag when X appears".
    CREATE TABLE user_rules (
        id               INTEGER PRIMARY KEY AUTOINCREMENT,
        name             TEXT NOT NULL,
        enabled          INTEGER NOT NULL DEFAULT 1,
        match_source     TEXT,            -- IME | evtx | MSI | WU | (any if NULL)
        match_code       TEXT,            -- exact event_code, e.g. 0x80240022
        match_contains   TEXT,            -- substring of the message (LIKE)
        match_severity   TEXT,            -- only events of this severity
        group_by_actor   INTEGER NOT NULL DEFAULT 0,  -- one finding per app, or one total
        min_count        INTEGER NOT NULL DEFAULT 1,
        severity         TEXT NOT NULL DEFAULT 'warn',     -- finding severity
        confidence       TEXT NOT NULL DEFAULT 'medium',
        title            TEXT NOT NULL,   -- supports {count} {actor} {code}
        recommendation   TEXT,            -- blank -> use error_map for match_code
        created_utc      TEXT
    );
    """,
    # --- Migration 7: config-profile states from Graph ---------------------------
    """
    -- Per-device configuration-profile assignment states fetched from Graph
    -- (deviceConfigurationStates). Device+time specific, so scoped to the case.
    -- setting_name NULL = the profile-level row; non-NULL rows are the failing
    -- settings of that profile.
    CREATE TABLE profile_states (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        case_id        INTEGER NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
        profile_id     TEXT,
        display_name   TEXT,
        platform_type  TEXT,
        state          TEXT,       -- compliant | nonCompliant | error | conflict | ...
        user_principal TEXT,
        setting_name   TEXT,
        setting_state  TEXT,
        error_code     TEXT,
        fetched_utc    TEXT
    );
    CREATE INDEX idx_profstates_case ON profile_states(case_id);
    """,
    # --- Migration 8: FK-path indexes ---------------------------------------------
    """
    -- Without these, ON DELETE CASCADE walks child tables by full scan — deleting
    -- one parsed case meant hundreds of scans over millions of events rows.
    CREATE INDEX IF NOT EXISTS idx_bundles_case      ON bundles(case_id);
    CREATE INDEX IF NOT EXISTS idx_events_artifact   ON events(artifact_id);
    CREATE INDEX IF NOT EXISTS idx_events_bundle     ON events(bundle_id);
    CREATE INDEX IF NOT EXISTS idx_fevidence_event   ON finding_evidence(event_id);
    CREATE INDEX IF NOT EXISTS idx_regvals_artifact  ON registry_values(artifact_id);
    CREATE INDEX IF NOT EXISTS idx_instapp_artifact  ON installed_apps(artifact_id);
    """,
    # --- Migration 9: health-script (proactive remediation) name cache -----------
    """
    -- PolicyId -> name/publisher/assignments, fetched from Graph once and reused
    -- across cases (same idea as app_map). `rca hs --resolve` fills it.
    CREATE TABLE IF NOT EXISTS hs_map (
        policy_id    TEXT PRIMARY KEY,
        display_name TEXT,
        publisher    TEXT,
        assignments  TEXT,
        fetched_utc  TEXT
    );
    """,
]
