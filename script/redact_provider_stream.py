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
    frame = dict(frame)
    # The parser reads either wrapper object, so both are minimized.
    for wrapper in ("data", "payload"):
        if isinstance(frame.get(wrapper), dict):
            frame[wrapper] = minimized_copilot_session_fields(frame.get("type"), frame[wrapper])
    return frame


def minimized_copilot_session_fields(kind, data):
    data = dict(data)
    if kind == "session.mcp_servers_loaded" and isinstance(data.get("servers"), list):
        data["servers"] = [
            {"name": "[redacted]", "status": server.get("status"), "source": server.get("source")}
            for server in data["servers"] if isinstance(server, dict)
        ]
    elif kind == "session.mcp_server_status_changed" and "serverName" in data:
        data["serverName"] = "[redacted]"
    elif kind == "session.usage_checkpoint":
        # Account usage and prompt-cache state; the parser reads none of it.
        data = {}
    return data


TOOL_OUTPUT = "[tool output redacted]"
CODEX_TOOL_ITEM_TYPES = {"command_execution", "mcp_tool_call", "local_shell_call", "function_call", "web_search"}
# Where a Codex tool item's result text may sit: every key the parser's
# textValue and commandResultSummary read.
CODEX_ITEM_PAYLOAD_KEYS = {
    "aggregated_output", "output", "stdout", "stderr", "result", "text", "message", "content", "error", "summary", "delta",
}
CODEX_ITEM_NON_ARGUMENT_KEYS = {"id", "type", "kind", "status", "exit_code", "exitCode"} | CODEX_ITEM_PAYLOAD_KEYS


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
}


def without_copilot_result_payload(fields):
    """Blank what a Copilot result carried; keep ids, flags and the outcome."""
    return {
        key: (
            error_placeholder(value) if key == "error"
            else TOOL_OUTPUT if key in COPILOT_RESULT_PAYLOAD_KEYS and value
            else value
        )
        for key, value in fields.items()
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


def is_copilot_tool_result(frame):
    kind = copilot_kind(frame)
    # The parser handles assistant, session and user frames before it looks
    # for tool results, so those keep their text.
    if kind.startswith(("assistant.", "session.", "user.")):
        return False
    looks_like_result = "tool" in kind and any(word in kind for word in ("result", "output", "complete", "progress"))
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
    kind = frame.get("type")
    wrapper = copilot_envelope(frame)
    if wrapper:  # Copilot unwraps envelopes, however deep, before reading them
        return dict(frame, **{wrapper: without_tool_output(frame[wrapper])})
    if kind == "system" and frame.get("subtype") in ("task_notification", "task_completed"):  # Claude subagents
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
    elif kind in ("item.started", "item.updated", "item.completed") and isinstance(frame.get("item"), dict):  # Codex
        item = frame["item"]
        # Only tool items: agent messages, reasoning and warning items keep
        # their text, which is what the conformance suite reads.
        if is_codex_tool_item(item):
            frame = dict(frame, item={
                key: (error_placeholder(value) if key == "error" else TOOL_OUTPUT if value else value)
                if key in CODEX_ITEM_PAYLOAD_KEYS else value
                for key, value in item.items()
            })
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
    kind = frame.get("type")
    if kind == "assistant":  # Claude Code
        for block in (frame.get("message") or {}).get("content") or []:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                yield block.get("name", "tool"), json.dumps(block.get("input"))
    elif kind == "tool.execution_start":  # Copilot
        # Arguments may sit under `arguments` or `input`; audit whatever the
        # parser could read, or the whole frame.
        yield copilot_payload(frame).get("toolName", "tool"), json.dumps(copilot_arguments(frame) or frame)
    elif kind in ("item.started", "item.completed"):  # Codex
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
            yield "file_change", json.dumps(paths)
    elif kind == "tool_call" and frame.get("subtype") == "started":  # Cursor
        yield "tool_call", json.dumps(frame.get("tool_call"))
    elif is_antigravity_step(frame):  # Antigravity
        step = frame.get("step_update") if isinstance(frame.get("step_update"), dict) else {}
        # The parser lowercases step_type and uppercases state before matching.
        if str(step.get("step_type") or "").lower() == "tool" and str(step.get("state") or "").upper() == "ACTIVE":
            yield step.get("tool_name", "tool"), json.dumps((step.get("tool_info") or {}).get("parameters"))
    else:
        call = copilot_tool_call(frame)
        if call:
            yield call


COPILOT_TYPE_KEYS = ("type", "event", "kind", "sessionUpdate", "name")
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
# What may precede a command: the start of the arguments, a shell separator
# or subshell opener, or the quote that opens a JSON string or `-c` script.
COMMAND_POSITION_PREFIX = re.compile(r"(?:^|[;&|(`\n{]|\$\(|\\?\")\s*$")
# Any rooted token is outside unless it is exactly /workspace, something below
# it, or /dev/null. A token rooted at a URL's `://` is not a path.
OUTSIDE_PATH_PATTERN = re.compile(
    r"(?<![\w.\-~/:])/(?!workspace(?:/|$|[\s\"'\\])|dev/null(?:$|[\s\"'\\]))"
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
    # A local file URL reads the disk however its slashes look.
    r"|(?i:\bfile:(?=/))"
)
ENV_DUMP_PATTERN = re.compile(r"(?:^|[\s;&|\"'])(?:env|printenv|set|export)(?:$|[\s;&|\"'])")
# `cd` with no directory, or `-`, moves to $HOME or the previous directory: a
# path that never appears in the arguments. Options (`-L`, `-P`, `-e`, `-@`,
# zsh's `-q` / `-s`) may come before the missing directory.
DIRECTORY_JUMP_PATTERN = re.compile(r"\b(?:cd|chdir)(?:\s+-[A-Za-z@]+)*(?:\s+--?)?\s*(?=$|[;&|)`}\"'\n])")


# Words that run the next word as a command: `command cd`, `builtin cd`,
# `eval cd`, `time cd`, each with or without options.
COMMAND_WRAPPERS = re.compile(r"(?:\b(?:builtin|command|eval|exec|nohup|time)(?:\s+-[A-Za-z]+)*\s+)+$")


def jumps_directory(command):
    for match in DIRECTORY_JUMP_PATTERN.finditer(command):
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
            leaves.append((str(key).lower() in COMMAND_ARGUMENT_KEYS, node))
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
                findings.append(f"line {number}: JSON that is not an object, cannot be audited")
                continue
            for name, arguments in tool_call_arguments(frame):
                # In a command, an executable path becomes its basename, so
                # `/usr/bin/env` is judged like `env` while `/bin/zsh` stops
                # counting as a path; anywhere else a path stays a path.
                # Shell-escaped strings are judged raw and decoded, and escapes
                # left over (printf, echo -e) are refused as obfuscation.
                leaves = argument_leaves(arguments)
                decoded = [shell_decoded(leaf) for _, leaf in leaves]
                forms = [
                    command_executables_as_basenames(json.dumps(text)) if is_command else json.dumps(text)
                    for (is_command, leaf), shell_text in zip(leaves, decoded)
                    for text in (leaf, shell_text)
                ]
                reached = any(OUTSIDE_PATH_PATTERN.search(form) or ENV_DUMP_PATTERN.search(form) for form in forms)
                reached = reached or any(jumps_directory(leaf) for leaf in decoded)
                if reached or any(has_escaped_bytes(leaf) for leaf in decoded):
                    findings.append(f"line {number}: {name} {arguments[:160]}")
    for finding in findings:
        print(finding)
    return 3 if findings else 0


COPILOT_RESULT_KEEP_KEYS = {"type", "id", "timestamp", "sessionId", "exitCode"}


def minimized(frame):
    """Drop the local inventory that init and session frames advertise."""
    wrapper = copilot_envelope(frame)
    if wrapper:  # Copilot unwraps envelopes, however deep, before reading them
        return dict(frame, **{wrapper: minimized(frame[wrapper])})
    if isinstance(frame.get("type"), str) and frame["type"].startswith("session."):
        return minimized_copilot_session(frame)
    if frame.get("type") == "result" and "sessionId" in frame:  # Copilot's terminal frame
        # It ends the turn and names the session; its usage block is premium
        # requests, timings and change counts the parser does not read.
        return {key: value for key, value in frame.items() if key in COPILOT_RESULT_KEEP_KEYS}
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
            if not isinstance(frame, dict):
                # A scalar or array frame can be neither minimized nor audited.
                sys.exit(f"line {number} of the capture is JSON but not an object; refusing to write a fixture")
            frame = without_tool_output(minimized(frame))
            print(json.dumps(redact(frame, pairs), ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
