#!/usr/bin/env python3
"""Redact a captured provider stdout stream before it becomes a test fixture.

Usage: redact_provider_stream.py RAW_JSONL WORKSPACE_PATH > FIXTURE_JSONL

The fixture must keep every field ASTRA's parsers read -- frame types, message
and tool ids, text, usage -- because those are what the conformance suite
tests. Everything that describes the capturing machine goes: home directory,
user name, email, host name, the scratch workspace path, the local tool / MCP /
plugin inventory that init and Copilot session frames advertise, account rate-limit details,
opaque signatures, and streamed tool-argument fragments. Lines that are not JSON pass through with string redaction
only.
"""

import getpass
import json
import os
import re
import socket
import sys

INIT_KEEP_KEYS = {
    # Claude Code and Cursor `{"type":"system","subtype":"init",...}`
    "type", "subtype", "session_id", "model", "cwd", "permissionMode", "uuid",
}
OPAQUE_VALUE_KEYS = {
    "signature", "encrypted_content", "encryptedContent", "reasoningId", "reasoningOpaque",
    "encryptedReasoning",
}
# Opaque only when long: Copilot's model_call_id is an encrypted blob, while
# Cursor's is a short per-call id that identifies its messages.
OPAQUE_WHEN_LONG_KEYS = {"model_call_id"}
OPAQUE_MIN_LENGTH = 80
TOKEN_PATTERNS = [
    re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bsk-[A-Za-z0-9_\-]{20,}\b"),
    re.compile(r"\bAIza[0-9A-Za-z_\-]{30,}\b"),
    re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._\-]{16,}"),
]
# Any other per-user macOS temp directory (the CLI's own scratch files).
MACOS_TEMP_PATTERN = re.compile(r"(?:/private)?/var/folders/[A-Za-z0-9_+\-]+/[A-Za-z0-9_+\-]+/[TC]\b")
# Claude Code's per-session scratch (`/private/tmp/claude-<uid>/…`) and the
# dash-escaped form of a temp path it derives project directory names from.
CLAUDE_SCRATCH_PATTERN = re.compile(r"(?:/private)?/tmp/claude-\d+/")
ESCAPED_TEMP_PATTERN = re.compile(r"-(?:private-)?var-folders-(?:[A-Za-z0-9_]+-)+?[TC]-")
# Streamed tool-argument fragments. ASTRA never reads their content (only that
# they arrived), and a path split across fragments evades string redaction.
TOOL_ARGUMENT_FRAGMENT_KEYS = {"partial_json", "inputDelta"}
# Organization-managed policy names (Codex echoes them in config warnings).
MANAGED_POLICY_PATTERN = re.compile(r"\(set by enterprise-managed requirements .*?\)\)")


def workspace_spellings(workspace):
    """Every way a tool may print the scratch workspace path.

    mktemp under $TMPDIR yields `.../T//astra-capture.X`, while tools print the
    normalized `/var/...` or the resolved `/private/var/...` form.
    """
    spellings = set()
    for path in (workspace, os.path.realpath(workspace)):
        if not path:
            continue
        normalized = re.sub(r"/+", "/", path).rstrip("/")
        spellings.update({path.rstrip("/"), normalized})
        if normalized.startswith("/private/var/"):
            spellings.add(normalized[len("/private"):])
        elif normalized.startswith("/var/"):
            spellings.add("/private" + normalized)
    return {spelling for spelling in spellings if len(spelling) > 1}


def replacements(workspace):
    home = os.path.expanduser("~")
    user = getpass.getuser()
    pairs = []
    for path in workspace_spellings(workspace):
        pairs.append((path, "/workspace"))
    pairs.append((home, "/Users/tester"))
    email = os.environ.get("ASTRA_CAPTURE_REDACT_EMAIL", "").strip()
    if email:
        pairs.append((email, "tester@example.com"))
    for host in {socket.gethostname(), socket.gethostname().split(".")[0]}:
        if host and len(host) > 3:
            pairs.append((host, "host"))
    if len(user) > 3:
        pairs.append((user, "tester"))
    # Longest first so a workspace under $HOME is rewritten before $HOME is.
    return sorted(pairs, key=lambda pair: len(pair[0]), reverse=True)


def redact_string(value, pairs):
    for old, new in pairs:
        value = value.replace(old, new)
    for pattern in TOKEN_PATTERNS:
        value = pattern.sub("[redacted-token]", value)
    value = MACOS_TEMP_PATTERN.sub("/tmp", value)
    value = CLAUDE_SCRATCH_PATTERN.sub("/tmp/claude/", value)
    value = ESCAPED_TEMP_PATTERN.sub("-tmp-", value)
    return MANAGED_POLICY_PATTERN.sub("(set by enterprise-managed requirements [redacted])", value)


def redact(value, pairs):
    if isinstance(value, str):
        return redact_string(value, pairs)
    if isinstance(value, list):
        return [redact(item, pairs) for item in value]
    if isinstance(value, dict):
        redacted = {}
        for key, item in value.items():
            if key in OPAQUE_VALUE_KEYS or (
                key in OPAQUE_WHEN_LONG_KEYS and isinstance(item, str) and len(item) >= OPAQUE_MIN_LENGTH
            ):
                redacted[key] = "[redacted]"
            elif key in TOOL_ARGUMENT_FRAGMENT_KEYS and isinstance(item, str) and item:
                redacted[key] = "…"
            else:
                redacted[key] = redact(item, pairs)
        return redacted
    return value


def minimized_copilot_session(frame):
    """Copilot advertises its MCP servers and prompt-cache state in session frames.

    ASTRA only reads `session_id` / `model` from `session.*` frames, so server
    names, instructions, tool metadata and cache state are dropped while the
    frame shape stays.
    """
    data = frame.get("data")
    if not isinstance(data, dict):
        return frame
    frame = dict(frame)
    data = dict(data)
    kind = frame.get("type")
    if kind == "session.mcp_servers_loaded" and isinstance(data.get("servers"), list):
        data["servers"] = [
            {"name": "[redacted]", "status": server.get("status"), "source": server.get("source")}
            for server in data["servers"] if isinstance(server, dict)
        ]
    elif kind == "session.mcp_server_status_changed" and "serverName" in data:
        data["serverName"] = "[redacted]"
    elif kind == "session.usage_checkpoint":
        data.pop("promptCacheBreakState", None)
    frame["data"] = data
    return frame


def minimized(frame):
    """Drop the local inventory that init and session frames advertise."""
    if isinstance(frame.get("type"), str) and frame["type"].startswith("session."):
        return minimized_copilot_session(frame)
    if frame.get("type") == "system" and frame.get("subtype") == "init":
        return {key: value for key, value in frame.items() if key in INIT_KEEP_KEYS}
    if frame.get("type") == "rate_limit_event" and isinstance(frame.get("rate_limit_info"), dict):
        return {"type": "rate_limit_event", "rate_limit_info": {"status": frame["rate_limit_info"].get("status")}}
    if frame.get("event") == "init" and isinstance(frame.get("init"), dict):
        frame = dict(frame)
        frame["init"] = {key: value for key, value in frame["init"].items() if key == "cwd"}
    return frame


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: redact_provider_stream.py RAW_JSONL WORKSPACE_PATH")
    raw_path, workspace = sys.argv[1], sys.argv[2]
    pairs = replacements(workspace)
    with open(raw_path, encoding="utf-8", errors="replace") as raw:
        for line in raw:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            try:
                frame = json.loads(line)
            except ValueError:
                print(redact_string(line, pairs))
                continue
            if isinstance(frame, dict):
                frame = minimized(frame)
            print(json.dumps(redact(frame, pairs), ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
