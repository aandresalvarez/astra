#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  ./script/capability_package.sh validate path/to/package.json
  ./script/capability_package.sh install-dev path/to/package.json
  ./script/capability_package.sh validate-dir path/to/capability-library
  ./script/capability_package.sh install-dev-dir path/to/capability-library

Validates ASTRA external capability package JSON. install-dev writes only to the
development channel capability library and never writes approval records.
USAGE
}

if [[ $# -ne 2 ]]; then
  usage
  exit 64
fi

ACTION="$1"
PACKAGE_PATH="$2"

case "$ACTION" in
  validate|install-dev|validate-dir|install-dev-dir) ;;
  *)
    usage
    exit 64
    ;;
esac

python3 - "$ACTION" "$PACKAGE_PATH" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

action = sys.argv[1]
input_path = Path(sys.argv[2]).expanduser()
directory_mode = action in {"validate-dir", "install-dev-dir"}
install_mode = action in {"install-dev", "install-dev-dir"}

DEV_LIBRARY = Path.home() / "Library" / "Application Support" / "AstraDev" / "Capabilities"
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+(\.[0-9]+)?$")
SHELL_META_COMMAND = set(";|&`$<>(){}[]\n\r")
SHELL_META_ARGUMENTS = set(";|&`$<>()\n\r")
KNOWN_BROWSER_ADAPTERS = {"googledrive", "googledrivebrowser", "drive", "github", "githubbrowser", "githubworkflow", "gh"}


def safe_file_name(package_id: str) -> str:
    mapped = "".join(ch if ch.isalnum() or ch in "-_" else "-" for ch in package_id)
    mapped = mapped.strip("-_")
    return mapped or "capability"


def has_shell_meta(value, chars):
    return any(ch in chars for ch in value)


def is_loopback(host):
    host = (host or "").strip().lower()
    return host in {"localhost", "127.0.0.1", "::1"} or host.endswith(".localhost")


def host_from_url(url):
    from urllib.parse import urlparse

    parsed = urlparse(url)
    return (parsed.scheme.lower() if parsed.scheme else None, parsed.hostname)


def issue(severity: str, code: str, message: str) -> dict:
    return {"severity": severity, "code": code, "message": message}


def discover_package_paths(path: Path) -> list[Path]:
    if directory_mode:
        if not path.is_dir():
            print(f"BLOCKER unreadable: {path} is not a directory", file=sys.stderr)
            sys.exit(1)
        files = []
        for candidate in path.rglob("*.json"):
            relative_parts = candidate.relative_to(path).parts
            if any(part.startswith(".") for part in relative_parts):
                continue
            files.append(candidate)
        if not files:
            print(f"BLOCKER emptyLibrary: no capability JSON files found in {path}", file=sys.stderr)
            sys.exit(1)
        return sorted(files)

    if path.is_dir():
        print("BLOCKER directoryInput: use validate-dir or install-dev-dir for capability libraries", file=sys.stderr)
        sys.exit(1)
    return [path]


def validate_package(path: Path) -> dict:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        return {
            "path": path,
            "package": None,
            "package_id": "",
            "safe_name": "",
            "issues": [issue("BLOCKER", "unreadable", f"{exc}")],
        }

    try:
        package = json.loads(raw)
    except json.JSONDecodeError as exc:
        return {
            "path": path,
            "package": None,
            "package_id": "",
            "safe_name": "",
            "issues": [issue("BLOCKER", "malformedJSON", f"{exc}")],
        }

    issues = []
    if not isinstance(package, dict):
        return {
            "path": path,
            "package": None,
            "package_id": "",
            "safe_name": "",
            "issues": [issue("BLOCKER", "malformedJSON", "Package JSON root must be an object.")],
        }

    package_id = str(package.get("id", "")).strip()
    safe_name = safe_file_name(package_id)
    if not package_id:
        issues.append(issue("BLOCKER", "invalidPackageID", "Package ID cannot be empty."))
    elif not SAFE_ID.match(package_id):
        issues.append(issue("BLOCKER", "invalidPackageID", "Package ID may contain only letters, numbers, dots, hyphens, and underscores."))

    if safe_name == "capability":
        issues.append(issue("BLOCKER", "invalidPackageID", "Package ID does not produce a usable capability filename."))

    version = str(package.get("version", "")).strip()
    if not SEMVER.match(version):
        issues.append(issue("BLOCKER", "invalidVersion", f"Package version {version or '<empty>'} is not semantic."))

    if "governance" not in package:
        issues.append(issue("WARNING", "missingGovernance", "Package will be imported as draft, admin-only, and requiring local review."))
    else:
        governance = package.get("governance") or {}
        if governance.get("approvalStatus") != "draft" or governance.get("visibility") != "adminOnly" or governance.get("requiresAdminApproval") is not True:
            issues.append(issue("WARNING", "approvalReset", "Local imports cannot approve themselves; approval will be reset to draft."))

    source = package.get("sourceMetadata")
    if source != {"id": "local", "displayName": "Local Capability Library", "kind": "local", "trustLevel": "local"}:
        issues.append(issue("WARNING", "localSourceNormalized", "Imported package source will be set to local."))

    payload_count = sum(len(package.get(key) or []) for key in ("skills", "connectors", "localTools", "mcpServers", "templates", "browserAdapters"))
    if payload_count == 0:
        issues.append(issue("WARNING", "emptyPayload", "Package declares no installable payload."))

    for tool in package.get("localTools") or []:
        name = str(tool.get("name") or tool.get("command") or "local tool")
        command = str(tool.get("command") or "").strip()
        arguments = str(tool.get("arguments") or "").strip()
        if not command:
            issues.append(issue("BLOCKER", "unsafeLocalTool", f"{name} has missing command."))
        elif command.startswith("-"):
            issues.append(issue("BLOCKER", "unsafeLocalTool", f"{name} command starts with a flag."))
        elif any(ch.isspace() for ch in command):
            issues.append(issue("BLOCKER", "unsafeLocalTool", f"{name} command contains whitespace."))
        elif has_shell_meta(command, SHELL_META_COMMAND):
            issues.append(issue("BLOCKER", "unsafeLocalTool", f"{name} command contains shell metacharacters."))
        if arguments and has_shell_meta(arguments, SHELL_META_ARGUMENTS):
            issues.append(issue("BLOCKER", "unsafeLocalTool", f"{name} arguments contain shell metacharacters."))

    for connector in package.get("connectors") or []:
        credential_hints = connector.get("credentialHints") or []
        if not credential_hints:
            continue
        base_url = str(connector.get("baseURL") or "").strip()
        if not base_url:
            continue
        scheme, host = host_from_url(base_url)
        if scheme != "https" and not (scheme == "http" and is_loopback(host)):
            name = str(connector.get("name") or connector.get("serviceType") or "connector")
            issues.append(issue("BLOCKER", "unsafeConnector", f"{name} cannot use credentials over remote cleartext HTTP."))

    for adapter in package.get("browserAdapters") or []:
        compact = str(adapter).strip().lower().replace("-", "").replace("_", "").replace(".", "")
        if compact not in KNOWN_BROWSER_ADAPTERS:
            issues.append(issue("BLOCKER", "unknownBrowserAdapter", f"{adapter} is not a known ASTRA browser adapter ID."))

    for server in package.get("mcpServers") or []:
        name = str(server.get("displayName") or server.get("id") or "MCP server")
        transport = str(server.get("transport") or "").lower()
        if transport == "stdio":
            command = str(server.get("command") or "").strip()
            args = " ".join(str(arg) for arg in (server.get("arguments") or []))
            if not command:
                issues.append(issue("BLOCKER", "unsafeMCPServer", f"{name} command is missing."))
            elif any(ch.isspace() for ch in command) or has_shell_meta(command, SHELL_META_COMMAND):
                issues.append(issue("BLOCKER", "unsafeMCPServer", f"{name} command is unsafe."))
            if args and has_shell_meta(args, SHELL_META_ARGUMENTS):
                issues.append(issue("BLOCKER", "unsafeMCPServer", f"{name} arguments contain shell metacharacters."))
        elif transport in {"http", "sse"}:
            url = str(server.get("url") or "").strip()
            scheme, host = host_from_url(url)
            if scheme != "https" and not (scheme == "http" and is_loopback(host)):
                issues.append(issue("BLOCKER", "unsafeMCPServer", f"{name} remote URL must use HTTPS, except loopback HTTP."))

    if package_id and install_mode:
        target = DEV_LIBRARY / f"{safe_name}.json"
        if target.exists():
            issues.append(issue("BLOCKER", "duplicatePackageID", f"{package_id} is already installed in the development capability library."))

    return {
        "path": path,
        "package": package,
        "package_id": package_id,
        "safe_name": safe_name,
        "issues": issues,
    }


def add_batch_collision_issues(results: list[dict]) -> None:
    ids: dict[str, list[dict]] = {}
    safe_names: dict[str, list[dict]] = {}
    for result in results:
        package_id = result["package_id"]
        safe_name = result["safe_name"]
        if package_id:
            ids.setdefault(package_id, []).append(result)
        if safe_name:
            safe_names.setdefault(safe_name, []).append(result)

    for package_id, matches in ids.items():
        if len(matches) > 1:
            paths = ", ".join(str(item["path"]) for item in matches)
            for item in matches:
                item["issues"].append(issue("BLOCKER", "duplicatePackageID", f"{package_id} appears more than once in this capability library: {paths}"))

    for safe_name, matches in safe_names.items():
        ids_for_name = sorted({item["package_id"] for item in matches})
        if len(ids_for_name) > 1:
            names = ", ".join(ids_for_name)
            for item in matches:
                item["issues"].append(issue("BLOCKER", "duplicatePackageFilename", f"Package IDs map to the same installed filename {safe_name}.json: {names}"))


def normalize_package_for_install(package: dict) -> dict:
    governance = dict(package.get("governance") or {})
    governance["approvalStatus"] = "draft"
    governance.setdefault("riskLevel", "medium")
    governance["visibility"] = "adminOnly"
    governance.setdefault("allowedRoles", [])
    governance.setdefault("allowedWorkspaceTags", [])
    governance["requiresAdminApproval"] = True
    governance["requiresExplicitUserConsent"] = True
    governance.setdefault("dataAccess", [])
    governance.setdefault("externalEffects", [])
    governance.pop("approvedBy", None)
    governance.pop("approvedAt", None)
    governance.setdefault("reviewTicketURL", None)
    if not str(governance.get("policyNotes") or "").strip():
        governance["policyNotes"] = "Local capability package imported from JSON and pending review."
    package["governance"] = governance
    package["sourceMetadata"] = {
        "id": "local",
        "displayName": "Local Capability Library",
        "kind": "local",
        "trustLevel": "local",
    }
    return package


paths = discover_package_paths(input_path)
results = [validate_package(path) for path in paths]
if len(results) > 1:
    add_batch_collision_issues(results)

for result in results:
    prefix = f"{result['path']}: " if len(results) > 1 else ""
    for item in result["issues"]:
        print(f"{prefix}{item['severity']} {item['code']}: {item['message']}")

has_blockers = any(item["severity"] == "BLOCKER" for result in results for item in result["issues"])
if has_blockers:
    sys.exit(1)

if not install_mode:
    if len(results) == 1:
        print("OK capability package is valid for local import")
    else:
        print(f"OK {len(results)} capability packages are valid for local import")
    sys.exit(0)

DEV_LIBRARY.mkdir(parents=True, exist_ok=True)
for result in results:
    package = normalize_package_for_install(result["package"])
    target = DEV_LIBRARY / f"{result['safe_name']}.json"
    target.write_text(json.dumps(package, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Installed {result['package_id']} to {target}")
PY
