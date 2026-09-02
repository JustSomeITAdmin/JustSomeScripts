"""Rule framework: the @rule decorator, the registry, and rule discovery.

A rule is a function (conn, case_id) -> list[Finding]. Decorate it with @rule and
it's registered automatically — no array to maintain. Rules come from two places:

  * built-in pack: rca/rules.py
  * your drop-in folder: config.RULES_DIR (default <repo>/custom_rules) — any
    *.py there is loaded by path at run time, so you can add/edit rules without
    reinstalling. (Each `rca` command is a fresh process, so edits apply next run.)
"""

from __future__ import annotations

import importlib.util
from dataclasses import dataclass, field

from rca import config

CONFIDENCE_RANK = {"high": 2, "medium": 1, "low": 0}


@dataclass
class Finding:
    rule_id: str
    title: str
    severity: str          # error | warn | info
    confidence: str        # high | medium | low
    summary: str
    recommendation: str
    evidence_event_ids: list[int] = field(default_factory=list)


def events_of(conn, case_id: int, provider: str, code: str | None = None,
              where: str = "", params: tuple = (), limit: int | None = None):
    """Provider-qualified event lookup for rules.

    Event ids collide across providers (Winlogon 7001/7002 vs HelloForBusiness
    7001/7002; Kernel-General 16 vs anything) and a bare LIKE on the provider
    name matches more than intended ('%WER%' hits Kernel-PoWER). Always ask for
    (provider, code) together; `provider` is matched as a substring of `actor`.
    """
    sql = ("SELECT id, ts_local, ts_utc, actor, event_code, severity, message FROM events "
           "WHERE case_id = ? AND source = 'evtx' AND actor LIKE ?")
    args: list = [case_id, f"%{provider}%"]
    if code is not None:
        sql += " AND event_code = ?"; args.append(str(code))
    if where:
        sql += f" AND ({where})"; args.extend(params)
    sql += " ORDER BY ts_utc"
    if limit:
        sql += f" LIMIT {int(limit)}"
    return conn.execute(sql, args).fetchall()


# (function, source) where source is "built-in" or the custom file name.
_REGISTRY: list[tuple] = []
_loaded = False
LOAD_ERRORS: list[str] = []


def rule(func):
    """Register a rule function. Use as @rule above the function."""
    source = "built-in" if func.__module__ == "rca.rules" else "custom"
    _REGISTRY.append((func, source))
    return func


def _load_custom_dir() -> None:
    d = config.RULES_DIR
    if not d.exists():
        return
    for path in sorted(d.glob("*.py")):
        if path.name.startswith("_"):
            continue
        spec = importlib.util.spec_from_file_location(f"rca_custom_{path.stem}", path)
        try:
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)  # @rule calls register as a side effect
        except Exception as exc:  # a broken custom rule shouldn't kill analysis
            LOAD_ERRORS.append(f"{path.name}: {type(exc).__name__}: {exc}")


def load_rules() -> list[tuple]:
    """Import built-ins + custom rules once; return [(func, source), ...]."""
    global _loaded
    if not _loaded:
        import rca.rules  # noqa: F401 — importing triggers @rule registration
        _load_custom_dir()
        _loaded = True
    return list(_REGISTRY)
