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


def dash_escaped(path):
    """The ways Claude Code folds a path into one directory name for its task
    output: `/` becomes `-`, and in newer versions every other non-alphanumeric
    character does too."""
    return {path.replace("/", "-"), re.sub(r"[^A-Za-z0-9]", "-", path)}


def replacements(workspace):
    """Exact machine strings: distinctive enough to replace anywhere."""
    home = os.path.expanduser("~")
    pairs = []
    for path in workspace_spellings(workspace):
        pairs.append((path, "/workspace"))
        # A workspace outside the var-folders temp root (a custom TMPDIR under
        # $HOME) also appears dash-escaped in Claude's task-output paths.
        pairs += [(escaped, "-workspace") for escaped in dash_escaped(path)]
    pairs.append((home, "/Users/tester"))
    pairs += [(escaped, "-Users-tester") for escaped in dash_escaped(home)]
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
            # Keys are strings a provider can fill with paths, hosts or tokens
            # too (a map keyed by file path). Two keys that redact alike keep
            # both entries: the later one gets a numbered suffix.
            published = redact_string(key, pairs) if isinstance(key, str) else key
            if published in redacted:
                suffix = 2
                while f"{published} ({suffix})" in redacted:
                    suffix += 1
                published = f"{published} ({suffix})"
            if key in OPAQUE_VALUE_KEYS or (
                key in OPAQUE_WHEN_LONG_KEYS and isinstance(item, str) and len(item) >= OPAQUE_MIN_LENGTH
            ):
                redacted[published] = "[redacted]"
            elif key in TOOL_ARGUMENT_FRAGMENT_KEYS and isinstance(item, str) and item:
                redacted[published] = "…"
            elif key in HOST_VALUE_KEYS and isinstance(item, str) and item.split(".")[0] == SHORT_HOST:
                redacted[published] = "host"
            else:
                redacted[published] = redact(item, pairs)
        return redacted
    return value


def minimized_copilot_session(frame, kind):
    """Copilot advertises its MCP servers and prompt-cache state in session frames.

    ASTRA only reads `session_id` / `model` from `session.*` frames, so server
    names, instructions, tool metadata and cache state are dropped while the
    frame shape stays.
    """
    # The frame itself is minimized too (its discriminator and envelope stay),
    # and so is either wrapper object the parser reads.
    frame = minimized_copilot_session_fields(kind, frame, keep=COPILOT_ENVELOPE_KEEP_KEYS)
    for wrapper in ("data", "payload"):
        if isinstance(frame.get(wrapper), dict):
            frame[wrapper] = minimized_copilot_session_fields(kind, frame[wrapper])
    return frame


def minimized_copilot_session_fields(kind, data, keep=frozenset()):
    """What a session frame keeps: the session's identity and model (all the
    parser reads from most of them), plus the MCP status frames' shape with
    server names redacted, and the shutdown frame's usage metrics."""
    kept = {key: value for key, value in data.items() if key in COPILOT_SESSION_KEEP_KEYS or key in keep}
    if isinstance(kept.get("session"), dict):
        kept["session"] = {key: value for key, value in kept["session"].items() if key in COPILOT_SESSION_KEEP_KEYS}
    if kind == "session.mcp_servers_loaded" and isinstance(data.get("servers"), list):
        kept["servers"] = [
            {"name": "[redacted]", "status": server.get("status"), "source": server.get("source")}
            for server in data["servers"] if isinstance(server, dict)
        ]
    elif kind == "session.mcp_server_status_changed":
        if "serverName" in data:
            kept["serverName"] = "[redacted]"
        if "status" in data:
            kept["status"] = data["status"]
    elif kind == "session.shutdown":
        # sessionShutdownEvents reads token, cost and request counts per model
        # and the API duration; nothing else survives.
        if isinstance(data.get("modelMetrics"), dict):
            kept["modelMetrics"] = {
                model: shutdown_metrics(entry) for model, entry in data["modelMetrics"].items() if isinstance(entry, dict)
            }
        kept.update({key: data[key] for key in SHUTDOWN_DURATION_KEYS if key in data})
    return kept


def shutdown_metrics(entry):
    metrics = {key: entry[key] for key in SHUTDOWN_METRIC_KEYS if key in entry}
    if isinstance(entry.get("usage"), dict):
        metrics["usage"] = {key: entry["usage"][key] for key in SHUTDOWN_METRIC_KEYS if key in entry["usage"]}
    if isinstance(entry.get("requests"), dict) and "count" in entry["requests"]:
        metrics["requests"] = {"count": entry["requests"]["count"]}
    return metrics


COPILOT_SESSION_KEEP_KEYS = {"session_id", "sessionId", "id", "model", "session"}
SHUTDOWN_METRIC_KEYS = {
    "inputTokens", "input_tokens", "promptTokens", "prompt_tokens",
    "cacheReadTokens", "cacheReadInputTokens", "cache_read_input_tokens",
    "cacheWriteTokens", "cacheCreationInputTokens", "cache_creation_input_tokens",
    "outputTokens", "output_tokens", "completionTokens", "completion_tokens",
    "costUSD", "cost_usd", "total_cost_usd",
}
SHUTDOWN_DURATION_KEYS = ("totalApiDurationMs", "durationMs", "duration_ms")


TOOL_OUTPUT = "[tool output redacted]"
CODEX_TOOL_ITEM_TYPES = {"command_execution", "mcp_tool_call", "local_shell_call", "function_call", "web_search"}
# Where a Codex tool item's result text may sit: every key the parser's
# textValue and commandResultSummary read.
CODEX_ITEM_PAYLOAD_KEYS = {
    "aggregated_output", "output", "stdout", "stderr", "result", "text", "message", "content", "error", "summary", "delta",
}
CODEX_ITEM_NON_ARGUMENT_KEYS = {"id", "type", "kind", "status", "exit_code", "exitCode"} | CODEX_ITEM_PAYLOAD_KEYS


def without_codex_tool_output(fields):
    """Blank a Codex tool item's result text, including inside the `data` and
    `item` objects the parser's textValue also reads from."""
    return {
        key: (error_placeholder(value) if key == "error" else TOOL_OUTPUT if value else value)
        if key in CODEX_ITEM_PAYLOAD_KEYS
        else without_codex_tool_output(value) if key in ("data", "item") and isinstance(value, dict)
        else value
        for key, value in fields.items()
    }


def codex_item_type(item):
    return next((item[key].lower() for key in ("type", "kind") if isinstance(item.get(key), str)), "unknown")


def is_codex_tool_item(item):
    """CodexStreamEventParser's tool test: a command, or any item whose type
    names a tool or that carries a `tool` or `name`, other than messages,
    reasoning and file changes, which it handles first."""
    item_type = codex_item_type(item)
    if item_type in CODEX_TOOL_ITEM_TYPES:
        return True
    if item_type in ("file_change", "agent_message", "message", "assistant_message") or "reasoning" in item_type:
        return False
    return "tool" in item_type or "tool" in item or "name" in item
# Copilot also emits result frames other than tool.execution_complete (the
# parser accepts any tool *result/output/complete* type or a toolResult key),
# and streams partial output and progress while a tool runs.
COPILOT_RESULT_PAYLOAD_KEYS = {
    "output", "result", "content", "text", "message", "toolResult", "detailedContent", "stdout", "stderr",
    "partialOutput", "progressMessage",
    # Everything else CopilotStreamEventParser.textValue reads as a result's text.
    "delta", "deltaContent", "delta_content", "chunk", "summary",
}


def without_copilot_result_payload(fields):
    """Blank what a Copilot result carried and keep only its identity,
    envelope and outcome. Anything else is dropped: tool telemetry (resolved
    file paths), and any field the parser does not know, which it would
    otherwise fall back to recording as part of the raw frame."""
    kept = {}
    for key, value in fields.items():
        if key == "error":
            kept[key] = error_placeholder(value)
        elif key in COPILOT_RESULT_PAYLOAD_KEYS:
            kept[key] = TOOL_OUTPUT if value else value
        elif key in ("data", "payload") and isinstance(value, dict):
            # The parser follows nested data objects for a result's text too.
            kept[key] = without_copilot_result_payload(value)
        elif key in COPILOT_RESULT_IDENTITY_KEYS:
            kept[key] = value
    return kept


# What a Copilot result keeps besides its (blanked) text: ids, the tool, the
# outcome flags, and the envelope the stream wraps every frame in.
COPILOT_RESULT_IDENTITY_KEYS = {
    "type", "event", "kind", "sessionUpdate", "name", "id", "timestamp", "parentId", "ephemeral", "data", "payload",
    "toolCallId", "toolUseId", "tool_call_id", "callId", "toolName", "tool", "model", "interactionId", "turnId",
    "rte", "success", "succeeded", "ok", "isError", "is_error", "exitCode", "status",
}


CODEX_FILE_CHANGE_PATH_KEYS = ("path", "file_path", "filePath", "filename", "name")
# What a Codex file change keeps: the parser reads its text (a diff, file
# contents) from many keys, so everything but identity, paths and kinds goes.
CODEX_FILE_CHANGE_KEEP_KEYS = {
    "id", "type", "status", "path", "file_path", "filePath", "filename", "name", "kind", "change_type", "changeType",
}


def without_file_change_payload(fields):
    kept = {}
    for key, value in fields.items():
        if key == "changes" and isinstance(value, list):
            kept[key] = [without_file_change_payload(change) if isinstance(change, dict) else TOOL_OUTPUT for change in value]
        elif key in CODEX_FILE_CHANGE_KEEP_KEYS or not value:
            kept[key] = value
        else:
            kept[key] = TOOL_OUTPUT
    return kept


def error_placeholder(error):
    # A failed tool's `error` is a flag, or an object whose `message` the
    # parsers read as the result text: stderr, file contents, a credential.
    if error is None or isinstance(error, bool):
        return error
    return {"message": TOOL_OUTPUT} if isinstance(error, dict) else TOOL_OUTPUT


COPILOT_CONVERSATION_TYPES = {
    "user.message", "assistant.turn_start", "assistant.turn_end", "assistant.message_start", "assistant.idle",
    "assistant.reasoning", "assistant.reasoning_delta", "assistant.tool_call_delta", "assistant.message_delta",
    "assistant.message",
}


def codex_kind(frame):
    """The frame's type as CodexStreamEventParser reads it, lowercased."""
    return next((frame[key].lower() for key in ("type", "event", "kind") if isinstance(frame.get(key), str)), "")


def is_copilot_tool_result(frame):
    kind = copilot_kind(frame)
    # The parser handles session frames and these conversation frames before
    # it looks for tool results, so they keep their text. Any other type, even
    # one prefixed `assistant.`, can be read as a tool result.
    if kind.startswith("session.") or kind in COPILOT_CONVERSATION_TYPES:
        return False
    # The parser reads any type containing `error` (or `failed`) as a failure
    # carrying the frame's text, so a tool's error frame is a result too.
    looks_like_result = "tool" in kind and any(
        word in kind for word in ("result", "output", "complete", "progress", "error", "fail")
    )
    return (looks_like_result and kind != "tool_call") or any(
        "toolResult" in container for container in (frame, copilot_payload(frame))
    )


def copilot_kind(frame):
    """The frame's type as CopilotStreamEventParser reads it: its own type
    keys first, then its `data` / `payload` object's."""
    return next(
        (
            container[key]
            for container in (frame, copilot_payload(frame))
            for key in COPILOT_TYPE_KEYS
            if isinstance(container.get(key), str)
        ),
        "",
    ).lower()


def copilot_envelope(frame):
    """The wrapper key of a Copilot envelope the parser unwraps (a frame typed
    event/message/data/payload around a typed object), or None."""
    if copilot_kind(frame) not in ("event", "message", "data", "payload"):
        return None
    for wrapper in ("data", "payload"):
        inner = frame.get(wrapper)
        if isinstance(inner, dict):
            return wrapper if any(isinstance(inner.get(key), str) for key in COPILOT_TYPE_KEYS) else None
    return None


def without_tool_output(frame):
    """Replace every provider's tool-result payload with a placeholder."""
    # Parsers lowercase the type before matching, so casing is no way around.
    kind = str(frame.get("type") or "").lower()
    wrapper = copilot_envelope(frame)
    if wrapper:  # Copilot unwraps envelopes, however deep, before reading them
        return {**envelope_fields(frame), wrapper: without_tool_output(frame[wrapper])}
    if kind == "system" and str(frame.get("subtype") or "").lower() in ("task_notification", "task_completed"):  # Claude subagents
        # The summary repeats the subagent's answer; its identity and status stay.
        return {key: (TOOL_OUTPUT if key == "summary" and value else value) for key, value in frame.items()}
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
        # The parser also reads a result from the frame itself and `payload`.
        frame = without_copilot_result_payload(frame)
        if isinstance(frame.get("payload"), dict):
            frame["payload"] = without_copilot_result_payload(frame["payload"])
        frame["data"] = dict(without_copilot_result_payload(frame["data"]), result={"content": TOOL_OUTPUT})
    elif codex_kind(frame) in ("item.started", "item.updated", "item.completed") and isinstance(frame.get("item"), dict):  # Codex
        item = frame["item"]
        # Only tool items: agent messages, reasoning and warning items keep
        # their text, which is what the conformance suite reads.
        if is_codex_tool_item(item):
            frame = dict(frame, item=without_codex_tool_output(item))
        elif codex_item_type(item) == "file_change":
            frame = dict(frame, item=without_file_change_payload(item))
    elif kind == "tool_call" and isinstance(frame.get("tool_call"), dict):  # Cursor
        # Keep the outcome key (`success` / `error`), drop what it carried.
        def blank(result):
            return {outcome: TOOL_OUTPUT for outcome in result} if isinstance(result, dict) else TOOL_OUTPUT
        frame = dict(frame, tool_call={
            name: (dict(call, result=blank(call["result"])) if isinstance(call, dict) and "result" in call else call)
            for name, call in frame["tool_call"].items()
        })
    elif is_copilot_tool_result(frame):  # Copilot's other result shapes
        frame = without_copilot_result_payload(frame)
        # The parser reads a result from either wrapper object.
        for wrapper in ("data", "payload"):
            if isinstance(frame.get(wrapper), dict):
                frame[wrapper] = without_copilot_result_payload(frame[wrapper])
    elif is_antigravity_step(frame) and isinstance(frame.get("step_update"), dict):  # Antigravity
        step = frame["step_update"]
        info = step.get("tool_info")
        if isinstance(info, dict) and ("output" in info or "error" in info):
            # A tool in ERROR reports its text in `error.message` instead.
            info = dict(info)
            if "output" in info:
                info["output"] = TOOL_OUTPUT
            if "error" in info:
                info["error"] = error_placeholder(info["error"])
            frame = dict(frame, step_update=dict(step, tool_info=info))
    return frame


def tool_call_arguments(frame):
    """The arguments of every tool call a frame starts, as JSON text."""
    kind = str(frame.get("type") or "").lower()
    if kind == "assistant":  # Claude Code
        for block in (frame.get("message") or {}).get("content") or []:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                yield block.get("name", "tool"), json.dumps(block.get("input"))
        # The CLI also repeats each call's input here; ASTRA does not read it,
        # but it is published, so it is audited like the block input.
        wire_inputs = frame.get("wire_tool_inputs")
        if isinstance(wire_inputs, dict):
            for tool_use_id, wire_input in wire_inputs.items():
                yield f"wire_tool_inputs {tool_use_id}", json.dumps(wire_input)
    elif kind == "tool.execution_start":  # Copilot
        # Arguments may sit under `arguments` or `input`; audit whatever the
        # parser could read, or the whole frame.
        yield copilot_payload(frame).get("toolName", "tool"), json.dumps(copilot_arguments(frame) or frame)
    elif codex_kind(frame) in ("item.started", "item.updated", "item.completed"):  # Codex
        item = frame.get("item") or {}
        # The parser records a tool call from a completed item too, so both
        # are audited.
        if is_codex_tool_item(item):
            arguments = {key: value for key, value in item.items() if key not in CODEX_ITEM_NON_ARGUMENT_KEYS}
            yield codex_item_type(item), json.dumps(arguments)
        elif codex_item_type(item) == "file_change":
            # Every path key the parser reads, on the item and on each change.
            entries = [item] + [change for change in item.get("changes") or [] if isinstance(change, dict)]
            paths = [entry[key] for entry in entries for key in CODEX_FILE_CHANGE_PATH_KEYS if key in entry]
            yield "file_change", json.dumps({"paths": paths})
    elif kind == "tool_call" and str(frame.get("subtype") or "").lower() == "started":  # Cursor
        yield "tool_call", json.dumps(frame.get("tool_call"))
    elif is_antigravity_step(frame):  # Antigravity
        step = frame.get("step_update") if isinstance(frame.get("step_update"), dict) else {}
        # The parser lowercases step_type and uppercases state before matching.
        if str(step.get("step_type") or "").lower() == "tool" and str(step.get("state") or "").upper() == "ACTIVE":
            info = step.get("tool_info") if isinstance(step.get("tool_info"), dict) else {}
            yield step.get("tool_name", "tool"), json.dumps(info.get("parameters"))
    else:
        call = copilot_tool_call(frame)
        if call:
            yield call
        yield from copilot_tool_requests(frame)


def copilot_tool_requests(frame):
    """Tool calls a Copilot assistant message announces in `toolRequests`.
    The parser only checks that they exist, but their arguments are published,
    so they are audited like the tool.execution_start that follows."""
    wrapper = copilot_envelope(frame)
    if wrapper:
        yield from copilot_tool_requests(frame[wrapper])
        return
    for container in (frame, copilot_payload(frame)):
        for key in ("toolRequests", "tool_requests"):
            requests = container.get(key)
            for request in requests if isinstance(requests, list) else []:
                if isinstance(request, dict):
                    arguments = {name: request[name] for name in COPILOT_ARGUMENT_KEYS if name in request}
                    yield request.get("name") or request.get("toolName") or "toolRequest", json.dumps(arguments or request)


COPILOT_TYPE_KEYS = ("type", "event", "kind", "sessionUpdate", "name")
COPILOT_ENVELOPE_KEEP_KEYS = frozenset(COPILOT_TYPE_KEYS) | {"id", "timestamp", "parentId", "ephemeral", "data", "payload"}
COPILOT_TOOL_ID_KEYS = ("tool", "toolName", "tool_call_id", "toolUseId", "callId")
# Where CopilotStreamEventParser reads a tool call's input: on the frame or on
# its `data` / `payload` object.
COPILOT_ARGUMENT_KEYS = ("input", "arguments", "args", "command", "cmd")


def copilot_payload(frame):
    for key in ("data", "payload"):
        if isinstance(frame.get(key), dict):
            return frame[key]
    return {}


def copilot_arguments(frame):
    containers = (copilot_payload(frame), frame)
    return {key: container[key] for container in containers for key in COPILOT_ARGUMENT_KEYS if key in container}


def copilot_tool_call(frame):
    """A Copilot tool call in any shape but tool.execution_start, as a
    (name, arguments JSON) pair, or None.

    Mirrors CopilotStreamEventParser.isToolUse: a type naming a tool use, call
    or start, or a tool identity on a frame that is not a result. A call whose
    input sits under no known key is audited whole.
    """
    payload = copilot_payload(frame)
    containers = (frame, payload)
    kind = copilot_kind(frame)
    if kind in ("event", "message", "data", "payload") and any(isinstance(payload.get(key), str) for key in COPILOT_TYPE_KEYS):
        return copilot_tool_call(payload)
    # Argument fragments; the execution_start that follows carries them whole.
    if kind == "assistant.tool_call_delta":
        return None
    is_result = "tool" in kind and any(word in kind for word in ("result", "output", "complete")) or any(
        "toolResult" in container for container in containers
    )
    uses_tool = "tool" in kind and any(word in kind for word in ("use", "call", "start"))
    identified = any(key in container for container in containers for key in COPILOT_TOOL_ID_KEYS)
    if not (uses_tool or (identified and not is_result)):
        return None
    arguments = copilot_arguments(frame)
    name = next(
        (container[key] for container in containers for key in ("toolName", "tool", "name") if isinstance(container.get(key), str)),
        kind or "tool",
    )
    return name, json.dumps(arguments or frame)


# After redaction the scratch workspace is /workspace. An executable named by
# its full path (`/bin/zsh`, `/usr/bin/sed`) is fine; any other absolute path,
# a home-relative path (`~/`, `$HOME`), a parent-directory escape, or an
# environment dump means the agent explored beyond the capture.
EXECUTABLE_PATTERN = re.compile(
    r"(?<![\w.\-])/(?:usr/(?:local/)?|opt/homebrew/)?s?bin/[A-Za-z0-9._+\-]+(?![\w/.\-])"
)
# What may precede a command in a shell command string: its start, a
# separator or subshell opener, or the quote (single, double or `$'`) that
# opens a script `eval` or `sh -c` runs. A quote anywhere else opens an
# ordinary argument, such as the text `echo "cd"` prints.
SHELL_SCRIPT_OPENER = r"(?:\beval|\b(?:ba|z|da|k|fi)?sh(?:\s+-[A-Za-z]+)*\s+-[A-Za-z]*c[A-Za-z]*)\s+\$?[\"']"
COMMAND_POSITION_PREFIX = re.compile(r"(?:^|[;&|(`\n{]|\$\(|" + SHELL_SCRIPT_OPENER + r")\s*$")
# Where an executable path is exempt from the path rule: the start of the
# command string (the opening quote of its JSON form) or after a separator. A
# quote inside the command opens an argument, so `cat "/usr/bin/private"` is a
# path, not an executable.
EXECUTABLE_POSITION_PREFIX = re.compile(r"(?:^\"|[;&|(`\n{]|\$\()\s*$")
# Any rooted token is outside unless it is exactly /workspace, something below
# it, or /dev/null. A token rooted at a URL's `://` is not a path.
OUTSIDE_PATH_PATTERN = re.compile(
    # After an allowed prefix, a backslash only ends the path as a JSON escape
    # of a quote or of whitespace: `/workspace\-private` is another directory.
    r"(?<![\w.\-~/:])/(?!workspace(?:/|$|[\s\"']|\\[\"'ntr])|dev/null(?:$|[\s\"']|\\[\"'ntr]))"
    r"|(?<![\w.\-])\.\.(?=/|[\s\"'\\]|$)"
    r"|(?<![\w])~[A-Za-z0-9._\-]*(?=/|[\s\"'\\]|$)"
    # An inherited variable that holds a path outside the workspace. `$PWD`
    # is the workspace itself; slicing it is refused below.
    r"|\$\{?(?:HOME|USER|LOGNAME|TMPDIR|TMP|TEMP|SHELL|PATH|OLDPWD|BASH|ZDOTDIR)\b"
    # A parameter expansion with an operator or a subscript can carve a path
    # out of any variable: `${SHELL:0:1}etc` is `/etc`, `${PWD%/*}` is the
    # parent, and zsh's `$PWD[1]` is `/`.
    r"|\$\{[#!]?(?:[A-Za-z_]\w*|\d+|[@*?$!-])(?:\[[^]]*\])?[:#%/^,@]"
    r"|\$\{?[A-Za-z_]\w*\["
    # A bare variable in front of `/` makes an absolute path when it is empty:
    # with `x=`, `$x/etc` is `/etc`. (`${x}/etc` already shows its `/etc`.)
    r"|\$(?!PWD\b)(?:[A-Za-z_]\w*|\d)(?=/(?!workspace(?:/|$|[\s\"']|\\[\"'ntr])))"
    # A local file URL reads the disk however its slashes look.
    r"|(?i:\bfile:(?=/))"
)
ENV_DUMP_PATTERN = re.compile(r"(?:^|[\s;&|\"'])(?:env|printenv|set|export)(?:$|[\s;&|\"'])")
# `cd` with no directory, or `-`, moves to $HOME or the previous directory: a
# path that never appears in the arguments. Options (`-L`, `-P`, `-e`, `-@`,
# zsh's `-q` / `-s`) may come before the missing directory.
# A redirection (`2>&1`, `>/dev/null`, `&>log`) is not a directory either.
REDIRECTION = r"(?:\s*\d*(?:&>>?|>>?&?|<&?|<<<?)\s*(?:&?\d+-?|\"[^\"]*\"|'[^']*'|[^\s;&|)`}\"']+))"
# After the options, the command ends (a separator, or the quote that closes
# an `eval` / `sh -c` script right after `cd`); a quote after whitespace opens
# a quoted directory operand instead.
DIRECTORY_JUMP_PATTERN = re.compile(
    r"\b(?:cd|chdir)(?:\s+-[A-Za-z@]+)*(?:\s+--?)?" + REDIRECTION + r"*(?:\s*(?=$|[;&|)`}\n])|(?=[\"']))"
)


# Words that run the next word as a command: `command cd`, `builtin cd`,
# `eval cd`, `time cd`, each with or without options.
COMMAND_WRAPPERS = re.compile(r"(?:\b(?:builtin|command|eval|exec|nohup|time)(?:\s+(?:-[A-Za-z]+|--))*\s+)+$")


# The workspace's parent, computed rather than written: `dirname "$PWD"`,
# `dirname $(pwd)`, `pwd | xargs dirname`. `$PWD` itself is allowed.
CURRENT_DIRECTORY_COMMAND = r"(?:pwd|realpath|readlink|greadlink)\b"
PARENT_OF_WORKSPACE_PATTERN = re.compile(
    r"\bdirname\b(?:\s+-\S+)*\s+[\"']?(?:\$\{?PWD\b|\$\(\s*" + CURRENT_DIRECTORY_COMMAND
    + r"|`\s*" + CURRENT_DIRECTORY_COMMAND + r"|\.[\"']?(?=$|[\s;&|)]))"
    + r"|\b" + CURRENT_DIRECTORY_COMMAND + r"[^;&\n]*\|\s*(?:xargs\s+)?dirname\b"
)


# A command word built by an expansion (`x=cd; $x`, `eval "$cmd"`,
# `$(printf cd)`, `{cd,}`) runs whatever it expands to, which the audit cannot
# see; it is refused like escaped bytes. So is one with an expansion glued on:
# `cd${IFS}` and `cd$x` (empty) both run a bare `cd`. After an `=` the word is
# an assignment, and the expansion its value.
VARIABLE_COMMAND_PATTERN = re.compile(r"\$\{?[A-Za-z_]\w*\}?|\$\(|`|\{[^\s{}]*,")
GLUED_WORD_PREFIX = re.compile(r"[^\s;&|()`{}<>\"'$\\=]*$")


def runs_variable_as_command(command):
    for match in VARIABLE_COMMAND_PATTERN.finditer(command):
        before = command[:match.start()]
        # Quoted, as in `"$x"`, it is still the command word.
        before = before[:-1] if before.endswith(("\"", "'")) else before
        before = before[:GLUED_WORD_PREFIX.search(before).start()]
        wrapper = COMMAND_WRAPPERS.search(before)
        if COMMAND_POSITION_PREFIX.search(before[:wrapper.start()] if wrapper else before):
            return True
    return False


def unquoted(command):
    """The command with backslash escapes and quote characters removed, as
    quote removal leaves its words: `c\\d` and `c""d` both run `cd`. Checked
    alongside the original, where quotes still mark `eval` / `sh -c` scripts."""
    return re.sub(r"\\(.)", r"\1", command).replace('"', "").replace("'", "")


# A `cd` whose only operands are expansions (`cd $x`, `cd ${x} $(true)`) is a
# bare `cd` when they expand to nothing, and moves to $HOME. `$PWD` is never
# empty, so an operand list that uses it is a real directory.
EXPANSION = r"(?:\$(?:[A-Za-z_]\w*|[0-9@*#?!$-]|\{[^}]*\}|\([^)]*\))|`[^`]*`)"
EMPTYABLE_DIRECTORY_PATTERN = re.compile(
    r"\b(?:cd|chdir)(?:\s+-[A-Za-z@]+)*(?:\s+--)?((?:\s+" + EXPANSION + r"+)+)"
    + REDIRECTION + r"*\s*(?=$|[;&|)`}\n\"'])"
)


def jumps_directory(command):
    matches = list(DIRECTORY_JUMP_PATTERN.finditer(command)) + [
        match for match in EMPTYABLE_DIRECTORY_PATTERN.finditer(command)
        if not re.search(r"\$\{?PWD\b", match.group(1))
    ]
    for match in matches:
        before = command[:match.start()]
        wrapper = COMMAND_WRAPPERS.search(before)
        if COMMAND_POSITION_PREFIX.search(before[:wrapper.start()] if wrapper else before):
            return True
    return False


def is_antigravity_step(frame):
    return isinstance(frame.get("event"), str) and frame["event"].lower() == "step_update"


ANSI_C_STRING = re.compile(r"\$'((?:[^'\\]|\\.)*)'")
ESCAPED_BYTES = re.compile(r"\\(?:x[0-9A-Fa-f]{1,2}|[0-7]{3}|u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8})")
# `printf '\57'` is `/` too. A one- or two-digit escape is otherwise usually a
# sed backreference, so it only counts next to a command that expands it.
SHORT_OCTAL_ESCAPE = re.compile(r"\\[0-7]{1,2}(?![0-7])")
ESCAPE_EXPANDING_COMMAND = re.compile(r"(?<![\w.\-])(?:printf|print|echo)(?![\w.\-])")


def has_escaped_bytes(command):
    return bool(ESCAPED_BYTES.search(command)) or bool(
        SHORT_OCTAL_ESCAPE.search(command) and ESCAPE_EXPANDING_COMMAND.search(command)
    )


# Argument keys whose strings a tool runs as a shell command. Only these get
# the executable-path exemption: a path given to a file tool is always a path.
COMMAND_ARGUMENT_KEYS = {"command", "cmd", "commandline", "script", "shell_command", "shellcommand"}
# A tool's whole input given as one plain string (a custom tool's `input`) is
# a command line too; as an object, its own keys decide.
COMMAND_ARGUMENT_KEYS |= {"input", "arguments", "args"}


def argument_leaves(arguments_json):
    """(is_command, text) for every string in a tool call's arguments, dict
    keys included. A string that holds JSON (Copilot sends arguments that way)
    is read as JSON."""
    try:
        value = json.loads(arguments_json)
    except ValueError:
        return [(False, arguments_json)]
    leaves = []

    def collect(node, key):
        if isinstance(node, str):
            if node.lstrip()[:1] in ("{", "["):
                try:
                    nested = json.loads(node)
                except ValueError:
                    nested = None
                if isinstance(nested, (dict, list)):
                    collect(nested, key)
                    return
            # A tool's whole input as one string (Antigravity's string
            # parameters) is a command line; in an object, the key decides.
            leaves.append((key is None or str(key).lower() in COMMAND_ARGUMENT_KEYS, node))
        elif isinstance(node, list):
            for item in node:
                collect(item, key)
        elif isinstance(node, dict):
            for child_key, item in node.items():
                leaves.append((False, str(child_key)))
                collect(item, child_key)

    collect(value, None)
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
        if EXECUTABLE_POSITION_PREFIX.search(arguments[:match.start()]):
            pieces += [arguments[last:match.start()], " " + os.path.basename(match.group(0))]
            last = match.end()
    return "".join(pieces) + arguments[last:]


AUDIT_FINDINGS_EXIT = 3
AUDIT_REFUSED_EXIT = 4


def audit(fixture_path):
    """Exit 3 when tool calls reach outside the workspace (the capture script
    lets an owner accept those after review), 4 when a frame cannot be audited
    at all (never accepted), 0 otherwise."""
    findings = []
    unauditable = []
    with open(fixture_path, encoding="utf-8") as fixture:
        for number, line in enumerate(fixture, 1):
            try:
                frame = json.loads(line)
            except ValueError:
                unauditable.append(f"line {number}: not JSON, cannot be audited")
                continue
            if not isinstance(frame, dict):
                unauditable.append(f"line {number}: JSON that is not an object, cannot be audited")
                continue
            try:
                findings += audit_frame(number, frame)
            except Exception as error:  # a shape the audit does not expect
                unauditable.append(f"line {number}: cannot be audited ({type(error).__name__}: {error})")
    for finding in unauditable + findings:
        print(finding)
    return AUDIT_REFUSED_EXIT if unauditable else AUDIT_FINDINGS_EXIT if findings else 0


def audit_frame(number, frame):
    findings = []
    for name, arguments in tool_call_arguments(frame):
        # In a command, an executable path becomes its basename, so
        # `/usr/bin/env` is judged like `env` while `/bin/zsh` stops
        # counting as a path; anywhere else a path stays a path.
        # Shell-escaped strings are judged raw and decoded, and escapes
        # left over (printf, echo -e) are refused as obfuscation.
        leaves = argument_leaves(arguments)
        forms = [
            (is_command, command_executables_as_basenames(json.dumps(text)) if is_command else json.dumps(text))
            for is_command, leaf in leaves
            for text in (leaf, shell_decoded(leaf))
        ]
        # Paths count in every argument. Shell syntax (an environment
        # dump, a directory jump, escapes that build bytes) only counts
        # in a command: prose that mentions `env` is not run.
        commands = [shell_decoded(leaf) for is_command, leaf in leaves if is_command]
        reached = (
            any(OUTSIDE_PATH_PATTERN.search(form) for _, form in forms)
            or any(ENV_DUMP_PATTERN.search(form) for is_command, form in forms if is_command)
            # Quote removal spells `env` from `e\\nv` or `e""nv` too.
            or any(ENV_DUMP_PATTERN.search(unquoted(command)) for command in commands)
            or any(jumps_directory(command) or jumps_directory(unquoted(command)) for command in commands)
            or any(PARENT_OF_WORKSPACE_PATTERN.search(command) for command in commands)
            or any(runs_variable_as_command(command) or runs_variable_as_command(unquoted(command)) for command in commands)
        )
        if reached or any(has_escaped_bytes(command) for command in commands):
            findings.append(f"line {number}: {name} {arguments[:160]}")
    return findings


COPILOT_RESULT_KEEP_KEYS = {"id", "timestamp", "sessionId", "exitCode"} | set(COPILOT_TYPE_KEYS)


def envelope_fields(frame):
    return {key: value for key, value in frame.items() if key in COPILOT_ENVELOPE_KEEP_KEYS}


def minimized(frame):
    """Drop the local inventory that init and session frames advertise."""
    wrapper = copilot_envelope(frame)
    if wrapper:  # Copilot unwraps envelopes, however deep, before reading them
        # The runtime reads only the wrapped object; the envelope keeps its
        # discriminator and identity, and any other sibling is dropped.
        return {**envelope_fields(frame), wrapper: minimized(frame[wrapper])}
    # Parsers lowercase the type before matching, so casing is no way around.
    kind = str(frame.get("type") or "").lower()
    # Copilot's type can sit under any of its discriminator keys.
    copilot = copilot_kind(frame)
    if copilot.startswith("session."):
        return minimized_copilot_session(frame, copilot)
    if copilot == "result" and any("sessionId" in container for container in (frame, copilot_payload(frame))):
        # Copilot's terminal frame ends the turn and names the session; its
        # usage block is premium requests, timings and change counts the parser
        # does not read. Its discriminator, whichever key holds it, stays.
        def kept(fields):
            return {key: value for key, value in fields.items() if key in COPILOT_RESULT_KEEP_KEYS}
        result = kept(frame)
        for wrapper in ("data", "payload"):
            if isinstance(frame.get(wrapper), dict):
                result[wrapper] = kept(frame[wrapper])
        return result
    if kind == "system" and str(frame.get("subtype") or "").lower() == "init":
        return {key: value for key, value in frame.items() if key in INIT_KEEP_KEYS}
    if kind == "rate_limit_event" and isinstance(frame.get("rate_limit_info"), dict):
        return {"type": "rate_limit_event", "rate_limit_info": {"status": frame["rate_limit_info"].get("status")}}
    if str(frame.get("event") or "").lower() == "init" and isinstance(frame.get("init"), dict):
        frame = dict(frame)
        frame["init"] = {key: value for key, value in frame["init"].items() if key == "cwd"}
    return frame


LITERAL_WORKSPACE_PATTERN = re.compile(r"(?<![\w.\-~/:])/workspace(?=/|$|[\s\"'\\,)\]}])")


def decoded_strings(value):
    """Every string a frame decodes to, dict keys included, and the strings
    inside a string that is itself JSON (Copilot's arguments). A raw line can
    spell `/` as `\\u002f`, which only the decoded value shows."""
    if isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from decoded_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from decoded_strings(item)
    elif isinstance(value, str):
        yield value
        if value.strip()[:1] in ("{", "[", "\""):
            try:
                inner = json.loads(value)
            except ValueError:
                return
            if inner != value:
                yield from decoded_strings(inner)


def names_literal_workspace(line):
    try:
        decoded = list(decoded_strings(json.loads(line)))
    except ValueError:
        decoded = []  # refused below as not JSON
    return any(
        LITERAL_WORKSPACE_PATTERN.search(text)
        for text in [line, *decoded, *map(shell_decoded, decoded)]
    )


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--audit":
        sys.exit(audit(sys.argv[2]))
    if len(sys.argv) != 3:
        sys.exit("usage: redact_provider_stream.py RAW_JSONL WORKSPACE_PATH | --audit FIXTURE_JSONL")
    raw_path, workspace = sys.argv[1], sys.argv[2]
    pairs = replacements(workspace)
    # The scratch workspace becomes `/workspace`, which the audit allows. A
    # literal `/workspace` already in the capture is some other directory (a
    # real one on this machine) that redaction would make indistinguishable
    # from the scratch workspace, so such a capture is refused.
    if "/workspace" not in workspace_spellings(workspace):
        with open(raw_path, encoding="utf-8", errors="replace") as raw:
            for number, line in enumerate(raw, 1):
                if names_literal_workspace(line):
                    sys.exit(f"line {number} of the capture names a literal /workspace path; refusing to write a fixture")
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
            if not isinstance(frame, dict):
                # A scalar or array frame can be neither minimized nor audited.
                sys.exit(f"line {number} of the capture is JSON but not an object; refusing to write a fixture")
            frame = without_tool_output(minimized(frame))
            print(json.dumps(redact(frame, pairs), ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
