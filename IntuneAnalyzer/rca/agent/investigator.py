"""The investigation loop: drive a tool-using model to a written RCA.

Read-only by design — the agent can only query; it never changes state. It's
seeded with the case overview, calls tools to gather evidence, and stops when it
writes a final report. A step cap prevents runaway loops on weaker models.
"""

from __future__ import annotations

import json
import sqlite3

from rca.agent import tools as toolmod
from rca.agent.llm import LLMResponse

SYSTEM_PROMPT = """\
You are an Intune/Windows root-cause analysis assistant. A diagnostics package
has already been parsed into a database; you investigate ONLY by calling the
provided tools — never invent log lines, codes, registry values, or app names.

Method:
1. Call case_overview first.
2. Review list_findings; open the most severe with get_finding to see evidence.
3. Corroborate with search_events / timeline / list_apps / inventory / regquery /
   detection_for_app as needed. Prefer evidence over assumption.
4. When you have enough, STOP calling tools and write the final report.

Rules:
- Cite evidence: finding ids, timestamps, event codes, registry keys.
- If something can't be determined from the data, say so plainly.
- A code's verdict of 'unknown' means it wasn't in the package — recommend the
  data needed (e.g. `rca collect-script`), don't guess.

Final report format (Markdown):
## Root cause
## Evidence
## Recommended fix
## Confidence (high/medium/low) — and what would raise it
"""


def investigate(conn: sqlite3.Connection, case_id: int, provider,
                max_steps: int = 14, on_step=None) -> dict:
    specs, dispatch = toolmod.build_tools(conn, case_id)
    overview = dispatch["case_overview"]({})
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content":
            "Investigate this case and produce the root-cause report.\n"
            f"Case overview: {json.dumps(overview)}"},
    ]

    trace = []
    nudges = 0
    for step in range(max_steps):
        resp: LLMResponse = provider.chat(messages, specs)

        if resp.tool_calls:
            messages.append(resp.raw or {"role": "assistant", "content": resp.content or ""})
            names = []
            for tc in resp.tool_calls:
                names.append(tc.name)
                fn = dispatch.get(tc.name)
                if fn is None:
                    result = {"error": f"unknown tool '{tc.name}'"}
                else:
                    try:
                        result = fn(tc.arguments or {})
                    except Exception as exc:  # surface to the model, don't crash
                        result = {"error": f"{type(exc).__name__}: {exc}"}
                trace.append({"step": step + 1, "tool": tc.name, "args": tc.arguments})
                messages.append({"role": "tool", "tool_name": tc.name,
                                 "content": json.dumps(result)[:6000]})
            if on_step:
                on_step(step + 1, names)
            continue

        text = (resp.content or "").strip()
        if text:
            return {"report": text, "trace": trace, "steps": step + 1}

        # Empty turn (no tool call, no text): nudge instead of accepting silence.
        if nudges < 2:
            nudges += 1
            messages.append(resp.raw or {"role": "assistant", "content": ""})
            messages.append({"role": "user", "content":
                "You returned an empty message. Either call a tool to gather more "
                "evidence, or write the final root-cause report now in the required "
                "Markdown format."})
            if on_step:
                on_step(step + 1, ["(nudge)"])
            continue
        return {"report": "(the model kept returning empty responses — try a stronger "
                          "model or raise --max-steps)", "trace": trace, "steps": step + 1}

    return {"report": "(reached the step limit before finishing — try --max-steps higher "
                      "or a stronger model)", "trace": trace, "steps": max_steps}
