"""Provider-agnostic chat-with-tools interface.

The investigator talks to whatever model `config.LLM_PROVIDER` selects. Today
that's Ollama (local, free, private). The interface is OpenAI-style tool calling
so adding an Anthropic/Claude provider later is a thin adapter — the agent loop
and tools don't change.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field

import requests

from rca import config


@dataclass
class ToolCall:
    name: str
    arguments: dict


@dataclass
class LLMResponse:
    content: str | None
    tool_calls: list[ToolCall] = field(default_factory=list)
    raw: dict | None = None          # the raw assistant message, to re-append


class LLMError(RuntimeError):
    pass


class OllamaProvider:
    """Local Ollama via its /api/chat endpoint (OpenAI-style tools)."""

    def __init__(self, host: str, model: str):
        self.host = host.rstrip("/")
        self.model = model

    @property
    def label(self) -> str:
        return f"ollama:{self.model}"

    def ping(self) -> None:
        """Raise LLMError with a friendly message if Ollama/model isn't ready."""
        try:
            tags = requests.get(f"{self.host}/api/tags", timeout=5).json()
        except requests.RequestException as exc:
            raise LLMError(f"Ollama not reachable at {self.host} — is it running? ({exc})")
        names = {m.get("name") for m in tags.get("models", [])}
        if self.model not in names and f"{self.model}:latest" not in names:
            raise LLMError(f"Model '{self.model}' not pulled. Run: ollama pull {self.model}")

    def chat(self, messages: list[dict], tools: list[dict]) -> LLMResponse:
        payload = {
            "model": self.model,
            "messages": messages,
            "tools": tools,
            "stream": False,
            "options": {"temperature": 0},
        }
        try:
            r = requests.post(f"{self.host}/api/chat", json=payload, timeout=900)
            r.raise_for_status()
        except requests.RequestException as exc:
            raise LLMError(f"Ollama chat failed: {exc}")
        msg = r.json().get("message", {})
        calls = []
        for tc in msg.get("tool_calls") or []:
            fn = tc.get("function", {})
            args = fn.get("arguments") or {}
            if isinstance(args, str):
                try:
                    args = json.loads(args or "{}")
                except json.JSONDecodeError:
                    args = {}
            calls.append(ToolCall(name=fn.get("name", ""), arguments=args))
        return LLMResponse(content=msg.get("content") or None, tool_calls=calls, raw=msg)


def get_provider(model: str | None = None):
    if config.LLM_PROVIDER == "ollama":
        return OllamaProvider(config.OLLAMA_HOST, model or config.OLLAMA_MODEL)
    if config.LLM_PROVIDER == "anthropic":
        raise LLMError("Anthropic provider not implemented yet — set RCA_LLM_PROVIDER=ollama. "
                       "(The interface is ready; the Claude adapter is the next add.)")
    raise LLMError(f"Unknown LLM provider: {config.LLM_PROVIDER}")
