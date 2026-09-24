#!/usr/bin/env python3
"""Redact a captured provider stdout stream before it becomes a test fixture.

Usage: redact_provider_stream.py RAW_JSONL WORKSPACE_PATH > FIXTURE_JSONL
       redact_provider_stream.py --audit FIXTURE_JSONL

The fixture must keep every field ASTRA's parsers read -- frame types, message
and tool ids, text, usage -- because those are what the conformance suite
tests. Everything that describes the capturing machine goes: home directory,
user name, email, host name, the scratch workspace path, the local tool / MCP /
plugin inventory that init and Copilot session frames advertise, account rate-limit details,
opaque signatures, streamed tool-argument fragments, and the content of every
tool result: an agent that reads outside the workspace must not carry what it
read into the repository. ASTRA only needs to see that a result arrived.

`--audit` lists tool calls in a redacted fixture that reach outside the
scratch workspace or dump the environment, and exits 3 if there are any.

A line that is not JSON can be neither minimized nor audited, so the redactor
refuses the whole capture instead of publishing it.
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
# Opaque only when long: Copilot's model_call_id, apiCallId,
# previousResponseId and reasoning block ids are ~500-character provider
# continuation blobs, while Cursor's model_call_id and every message, tool and
# session id are short and are what the conformance suite keys on.
OPAQUE_WHEN_LONG_KEYS = {"model_call_id", "apiCallId", "previousResponseId", "id"}
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
    """Exact machine strings: distinctive enough to replace anywhere."""
    home = os.path.expanduser("~")
    pairs = []
    for path in workspace_spellings(workspace):
        pairs.append((path, "/workspace"))
    pairs.append((home, "/Users/tester"))
    email = os.environ.get("ASTRA_CAPTURE_REDACT_EMAIL", "").strip()
    if email:
        pairs.append((email, "tester@example.com"))
    # Longest first so a workspace under $HOME is rewritten before $HOME is.
    return sorted(pairs, key=lambda pair: len(pair[0]), reverse=True)


# The login and host name can be ordinary words ("will"), so they are replaced
# only where they identify the machine: as a path component, as `<host>.local`,
# or as the whole value of a host field. Prose keeps its words.
USER_PATH_PATTERN = re.compile(r"(?<=/)" + re.escape(getpass.getuser()) + r"(?=/|$|[\"'\s:])")
SHORT_HOST = socket.gethostname().split(".")[0]
HOST_LOCAL_PATTERN = re.compile(r"\b" + re.escape(SHORT_HOST) + r"\.local\b")
HOST_VALUE_KEYS = {"hostname", "host", "hostName", "machine", "computerName", "computer_name"}


def redact_string(value, pairs):
    for old, new in pairs:
        value = value.replace(old, new)
    value = USER_PATH_PATTERN.sub("tester", value)
    value = HOST_LOCAL_PATTERN.sub("host.local", value)
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
            elif key in HOST_VALUE_KEYS and isinstance(item, str) and item.split(".")[0] == SHORT_HOST:
                redacted[key] = "host"
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


TOOL_OUTPUT = "[tool output redacted]"
CODEX_TOOL_ITEM_TYPES = {"command_execution", "mcp_tool_call", "local_shell_call", "function_call", "web_search"}


def without_tool_output(frame):
    """Replace every provider's tool-result payload with a placeholder."""
    kind = frame.get("type")
    if kind == "user":  # Claude Code and Cursor tool results
        frame = dict(frame)
        frame.pop("tool_use_result", None)
        message = frame.get("message")
        if isinstance(message, dict) and isinstance(message.get("content"), list):
            message = dict(message)
            # Keep only the result's identity: its payload may sit in `content`
            # or `text` (both are parsed), so nothing else survives.
            message["content"] = [
                {
                    **{key: block[key] for key in ("type", "tool_use_id", "is_error") if key in block},
                    "content": TOOL_OUTPUT,
                }
                if isinstance(block, dict) and block.get("type") == "tool_result" else block
                for block in message["content"]
            ]
            frame["message"] = message
    elif kind == "tool.execution_complete" and isinstance(frame.get("data"), dict):  # Copilot
        frame = dict(frame, data=dict(frame["data"], result={"content": TOOL_OUTPUT}))
    elif kind in ("item.started", "item.updated", "item.completed") and isinstance(frame.get("item"), dict):  # Codex
        item = frame["item"]
        # Only tool items: agent messages, reasoning and warning items keep
        # their text, which is what the conformance suite reads.
        payload_keys = [
            key for key in ("aggregated_output", "output", "stdout", "stderr", "result", "text", "message")
            if key in item
        ]
        if payload_keys and item.get("type") in CODEX_TOOL_ITEM_TYPES:
            frame = dict(frame, item=dict(item, **{key: TOOL_OUTPUT if item[key] else item[key] for key in payload_keys}))
    elif kind == "tool_call" and isinstance(frame.get("tool_call"), dict):  # Cursor
        # Keep the outcome key (`success` / `error`), drop what it carried.
        def blank(result):
            return {outcome: TOOL_OUTPUT for outcome in result} if isinstance(result, dict) else TOOL_OUTPUT
        frame = dict(frame, tool_call={
            name: (dict(call, result=blank(call["result"])) if isinstance(call, dict) and "result" in call else call)
            for name, call in frame["tool_call"].items()
        })
    elif frame.get("event") == "step_update" and isinstance(frame.get("step_update"), dict):  # Antigravity
        step = frame["step_update"]
        info = step.get("tool_info")
        if isinstance(info, dict) and "output" in info:
            frame = dict(frame, step_update=dict(step, tool_info=dict(info, output=TOOL_OUTPUT)))
    return frame


def tool_call_arguments(frame):
    """The arguments of every tool call a frame starts, as JSON text."""
    kind = frame.get("type")
    if kind == "assistant":  # Claude Code
        for block in (frame.get("message") or {}).get("content") or []:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                yield block.get("name", "tool"), json.dumps(block.get("input"))
    elif kind == "tool.execution_start":  # Copilot
        data = frame.get("data") or {}
        yield data.get("toolName", "tool"), json.dumps(data.get("arguments"))
    elif kind == "item.started":  # Codex
        item = frame.get("item") or {}
        if item.get("type") == "command_execution":
            yield "command_execution", json.dumps(item.get("command"))
    elif kind == "tool_call" and frame.get("subtype") == "started":  # Cursor
        yield "tool_call", json.dumps(frame.get("tool_call"))
    elif frame.get("event") == "step_update":  # Antigravity
        step = frame.get("step_update") or {}
        if step.get("step_type") == "tool" and step.get("state") == "ACTIVE":
            yield step.get("tool_name", "tool"), json.dumps((step.get("tool_info") or {}).get("parameters"))


# After redaction the scratch workspace is /workspace. An executable named by
# its full path (`/bin/zsh`, `/usr/bin/sed`) is fine; any other absolute path,
# a home-relative path (`~/`, `$HOME`), a parent-directory escape, or an
# environment dump means the agent explored beyond the capture.
EXECUTABLE_PATTERN = re.compile(
    r"(?<![\w.\-])/(?:usr/(?:local/)?|opt/homebrew/)?s?bin/[A-Za-z0-9._+\-]+(?![\w/.\-])"
)
# What may precede a command: the start of the arguments, a shell separator
# or subshell opener, or the quote that opens a JSON string or `-c` script.
COMMAND_POSITION_PREFIX = re.compile(r"(?:^|[;&|(`\n{]|\$\(|\\?\")\s*$")
# Any rooted token is outside unless it is exactly /workspace, something below
# it, or /dev/null. A token rooted at a URL's `://` is not a path.
OUTSIDE_PATH_PATTERN = re.compile(
    r"(?<![\w.\-~/:])/(?!workspace(?:/|$|[\s\"'\\])|dev/null(?:$|[\s\"'\\]))"
    r"|(?<![\w.\-])\.\.(?=/|[\s\"'\\]|$)"
    r"|(?<![\w])~[A-Za-z0-9._\-]*(?=/|[\s\"'\\]|$)"
    r"|\$\{?(?:HOME|USER|LOGNAME|TMPDIR)\b"
)
ENV_DUMP_PATTERN = re.compile(r"(?:^|[\s;&|\"'])(?:env|printenv|set|export)(?:$|[\s;&|\"'])")


ANSI_C_STRING = re.compile(r"\$'((?:[^'\\]|\\.)*)'")
ESCAPED_BYTES = re.compile(r"\\(?:x[0-9A-Fa-f]{1,2}|[0-7]{3}|u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8})")


def string_leaves(arguments_json):
    try:
        value = json.loads(arguments_json)
    except ValueError:
        return [arguments_json]
    leaves = []

    def collect(node):
        if isinstance(node, str):
            leaves.append(node)
        elif isinstance(node, list):
            for item in node:
                collect(item)
        elif isinstance(node, dict):
            for item in node.values():
                collect(item)

    collect(value)
    return leaves


def shell_decoded(leaf):
    """A string with its shell `$'…'` segments decoded.

    `cat $'\\x2fetc\\x2fpasswd'` reads /etc/passwd without a literal rooted
    path, so the audit also checks the decoded form.
    """
    return ANSI_C_STRING.sub(
        lambda match: match.group(1).encode("utf-8", "backslashreplace").decode("unicode_escape", "replace"),
        leaf,
    )


def command_executables_as_basenames(arguments):
    """Replace an executable path in command position by its basename.

    `/bin/zsh -lc …` stops counting as a path and `/usr/bin/env` is judged like
    `env`, while a path argument such as `cat /usr/bin/private` stays a path.
    """
    pieces, last = [], 0
    for match in EXECUTABLE_PATTERN.finditer(arguments):
        if COMMAND_POSITION_PREFIX.search(arguments[:match.start()]):
            pieces += [arguments[last:match.start()], " " + os.path.basename(match.group(0))]
            last = match.end()
    return "".join(pieces) + arguments[last:]


def audit(fixture_path):
    findings = []
    with open(fixture_path, encoding="utf-8") as fixture:
        for number, line in enumerate(fixture, 1):
            try:
                frame = json.loads(line)
            except ValueError:
                findings.append(f"line {number}: not JSON, cannot be audited")
                continue
            if not isinstance(frame, dict):
                continue
            for name, arguments in tool_call_arguments(frame):
                # An executable path becomes its basename, so `/usr/bin/env` is
                # judged like `env` while `/bin/zsh` stops counting as a path.
                # Shell-escaped strings are judged decoded, and escapes left
                # over (printf, echo -e) are refused as obfuscation.
                decoded = [shell_decoded(leaf) for leaf in string_leaves(arguments)]
                forms = [arguments] + [json.dumps(leaf) for leaf in decoded]
                reached = any(
                    OUTSIDE_PATH_PATTERN.search(reach) or ENV_DUMP_PATTERN.search(reach)
                    for reach in map(command_executables_as_basenames, forms)
                )
                if reached or any(ESCAPED_BYTES.search(leaf) for leaf in decoded):
                    findings.append(f"line {number}: {name} {arguments[:160]}")
    for finding in findings:
        print(finding)
    return 3 if findings else 0


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
    if len(sys.argv) == 3 and sys.argv[1] == "--audit":
        sys.exit(audit(sys.argv[2]))
    if len(sys.argv) != 3:
        sys.exit("usage: redact_provider_stream.py RAW_JSONL WORKSPACE_PATH | --audit FIXTURE_JSONL")
    raw_path, workspace = sys.argv[1], sys.argv[2]
    pairs = replacements(workspace)
    with open(raw_path, encoding="utf-8", errors="replace") as raw:
        for number, line in enumerate(raw, 1):
            line = line.rstrip("\n")
            if not line.strip():
                continue
            try:
                frame = json.loads(line)
            except ValueError:
                # A malformed frame cannot have its tool output removed or its
                # tool calls audited, so it is never published.
                sys.exit(f"line {number} of the capture is not JSON; refusing to write a fixture")
            if isinstance(frame, dict):
                frame = without_tool_output(minimized(frame))
            print(json.dumps(redact(frame, pairs), ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
