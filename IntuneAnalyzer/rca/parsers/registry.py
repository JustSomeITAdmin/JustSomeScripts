"""Parser for exported .reg files (Windows Registry Editor 5.00 format, UTF-16).

Yields one block per key: {key_path, hive, values=[(name, type, data), ...]}.
Registry data is point-in-time state (no timestamps), so it does not become
timeline events — the loader stores it in registry_values / installed_apps.

Handles string, dword, and the hex(...) binary/expand_sz/multi_sz/qword forms,
including the trailing-backslash line continuations that hex blobs use.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Iterator

_KEY_RE = re.compile(r"^\[(?P<key>.+)\]\s*$")
_VALUE_RE = re.compile(r'^(?:"(?P<name>(?:[^"\\]|\\.)*)"|(?P<default>@))=(?P<rest>.*)$')
_STR_RE = re.compile(r'^"(?P<s>(?:[^"\\]|\\.)*)"$')
_DWORD_RE = re.compile(r"^dword:(?P<h>[0-9a-fA-F]{1,8})$")
_HEX_RE = re.compile(r"^hex(?:\((?P<t>[0-9a-fA-F]+)\))?:(?P<data>.*)$")

_HEX_TYPE = {None: "binary", "2": "expand_sz", "7": "multi_sz", "b": "qword", "4": "dword"}
_MAX_DATA = 1000  # truncate large blobs (e.g. cert binaries)


@dataclass
class RegBlock:
    key_path: str
    hive: str
    values: list[tuple[str | None, str, str]] = field(default_factory=list)


def _unescape(s: str) -> str:
    return s.replace('\\\\', '\\').replace('\\"', '"')


def _join_continuations(lines: list[str]) -> list[str]:
    """Merge trailing-backslash continuation lines (used by hex values)."""
    out: list[str] = []
    buf = ""
    for ln in lines:
        cur = buf + ln
        if cur.rstrip().endswith("\\"):
            buf = cur.rstrip()[:-1]  # drop the backslash, keep accumulating
        else:
            out.append(cur)
            buf = ""
    if buf:
        out.append(buf)
    return out


def _parse_value(rest: str) -> tuple[str, str]:
    """Return (value_type, value_data) for the right-hand side of a value line."""
    rest = rest.strip()
    if m := _STR_RE.match(rest):
        return "sz", _unescape(m.group("s"))[:_MAX_DATA]
    if m := _DWORD_RE.match(rest):
        return "dword", str(int(m.group("h"), 16))
    if m := _HEX_RE.match(rest):
        vtype = _HEX_TYPE.get(m.group("t"), "binary")
        data = m.group("data").replace(" ", "")
        return vtype, data[:_MAX_DATA]
    return "unknown", rest[:_MAX_DATA]


def parse_reg(text: str) -> Iterator[RegBlock]:
    lines = _join_continuations(text.splitlines())
    block: RegBlock | None = None
    for ln in lines:
        if not ln.strip() or ln.startswith("Windows Registry Editor"):
            continue
        if m := _KEY_RE.match(ln):
            if block is not None:
                yield block
            key = m.group("key")
            hive = key.split("\\", 1)[0]
            block = RegBlock(key_path=key, hive=hive)
            continue
        if block is None:
            continue
        if m := _VALUE_RE.match(ln):
            name = None if m.group("default") else _unescape(m.group("name"))
            vtype, vdata = _parse_value(m.group("rest"))
            block.values.append((name, vtype, vdata))
    if block is not None:
        yield block
