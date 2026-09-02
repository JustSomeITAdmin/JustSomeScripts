# Custom rules

Drop a `*.py` file in this folder to add your own RCA rules. They're loaded by
path each time you run `rca analyze` — **no reinstall needed**. Edit and re-run.

A rule is a function `(conn, case_id) -> list[Finding]` decorated with `@rule`.
It queries the normalized tables (`events`, `installed_apps`, `registry_values`)
and returns `Finding`s, each linking to the events that prove it.

Files starting with `_` are ignored. Check what's loaded with `rca rules`.

## Template — copy into e.g. `my_rules.py`

```python
from rca.ruleset import rule, Finding


@rule
def rule_bitlocker_recovery_events(conn, case_id):
    # 1) query the normalized data
    rows = conn.execute(
        """SELECT id, ts_local, ts_utc, message FROM events
           WHERE case_id = ? AND source = 'evtx'
                 AND actor = 'Microsoft-Windows-BitLocker-API'
                 AND severity IN ('error', 'critical')""",
        (case_id,),
    ).fetchall()
    if not rows:
        return []                      # no finding for this case

    # 2) return one or more Findings, citing the events as evidence
    return [Finding(
        rule_id="bitlocker_recovery",
        title=f"BitLocker errors in event log ({len(rows)})",
        severity="warn",               # error | warn | info
        confidence="medium",           # high | medium | low
        summary="BitLocker-API logged errors; the device may have entered recovery.",
        recommendation="Check TPM/PCR state and recent firmware/secure-boot changes.",
        evidence_event_ids=[r["id"] for r in rows],
    )]
```

## Tips

- **Error-code meanings live in `error_codes.json`** (repo root), not in rules.
  To teach the tool a new code, add a row there and look it up with
  `from rca import errormap; errormap.lookup("0x...")`. Most "new rule" needs are
  really just a new code — no rule required.
- Columns you'll use most on `events`: `source`, `severity`, `event_code`,
  `actor`, `message`, `ts_utc`/`ts_local`, and `id` (for evidence).
- `rca rules` lists everything that will run; load errors show up there too.
