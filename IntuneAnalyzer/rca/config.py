"""Central paths and constants.

All runtime state lives under one home directory so the tool is portable.

  * Source checkout (this repo has a pyproject.toml next to the package): home is
    the repo root — keeps `data/`, `custom_rules/`, `error_codes.json` in the tree
    for development.
  * Installed as a wheel on another machine (site-packages, not writable): home is
    a per-user folder, `~/.intune-rca` (override with RCA_HOME).

Any individual path can still be overridden: RCA_DATA_DIR, RCA_RULES_DIR,
RCA_ERROR_MAP.
"""

from __future__ import annotations

import os
from pathlib import Path

_PKG_DIR = Path(__file__).resolve().parent
REPO_ROOT = _PKG_DIR.parent

# A source checkout ships pyproject.toml beside the package; a wheel install does not.
_IS_SOURCE_CHECKOUT = (REPO_ROOT / "pyproject.toml").exists()
HOME = (REPO_ROOT if _IS_SOURCE_CHECKOUT
        else Path(os.environ.get("RCA_HOME", Path.home() / ".intune-rca")))


def _load_dotenv() -> None:
    """Load .env into the environment (no overriding real vars). Checks CWD, HOME,
    and the repo root so creds work whether run from source or an install."""
    for env in (Path.cwd() / ".env", HOME / ".env", REPO_ROOT / ".env"):
        if not env.exists():
            continue
        for line in env.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            os.environ.setdefault(key.strip(), val.strip().strip('"').strip("'"))


_load_dotenv()

DATA_DIR = Path(os.environ.get("RCA_DATA_DIR", HOME / "data"))
DB_PATH = DATA_DIR / "cases.db"

# Per-case materialized files (expanded CABs, extracted artifacts) live here.
CASES_DIR = DATA_DIR / "cases"

# Microsoft Graph credentials (from .env or the environment).
GRAPH_TENANT_ID = os.environ.get("GRAPH_TENANT_ID")
GRAPH_CLIENT_ID = os.environ.get("GRAPH_CLIENT_ID")
GRAPH_CLIENT_SECRET = os.environ.get("GRAPH_CLIENT_SECRET")
MSAL_CACHE_PATH = DATA_DIR / ".msal_cache.bin"

# Drop-in folder for your own rules (*.py), and the editable error-code map.
# Both are loaded by path at run time, so edits apply without reinstalling.
RULES_DIR = Path(os.environ.get("RCA_RULES_DIR", HOME / "custom_rules"))
ERROR_MAP_PATH = Path(os.environ.get("RCA_ERROR_MAP", HOME / "error_codes.json"))

# LLM agent (Phase 4). Provider-agnostic: 'ollama' (local, default) or 'anthropic'.
LLM_PROVIDER = os.environ.get("RCA_LLM_PROVIDER", "ollama")
OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://localhost:11434")
OLLAMA_MODEL = os.environ.get("RCA_OLLAMA_MODEL", "qwen2.5:7b")
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY")
ANTHROPIC_MODEL = os.environ.get("RCA_ANTHROPIC_MODEL", "claude-sonnet-4-6")

# Microsoft-published public client ("Microsoft Graph Command Line Tools").
# Lets us do interactive/device-code delegated auth with NO app registration —
# it already has the localhost redirect and public-client flow enabled.
WELLKNOWN_PUBLIC_CLIENT_ID = "14d82eec-204b-4c2f-b7e8-296a70dab67e"


def case_raw_dir(case_id: int) -> Path:
    """Directory holding materialized (on-disk) artifacts for a case."""
    return CASES_DIR / str(case_id) / "raw"


def ensure_dirs() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    CASES_DIR.mkdir(parents=True, exist_ok=True)
