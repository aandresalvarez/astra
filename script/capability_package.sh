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
import shutil
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
MANIFEST_NAME = "capability.json"
ALLOWED_ICON_EXTENSIONS = {".pdf", ".png", ".svg"}
MAX_ICON_BYTES = 512 * 1024


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


def list_field(package, key, issues):
    value = package.get(key)
    if value is None:
        return []
    if not isinstance(value, list):
        issues.append(issue("BLOCKER", "malformedJSON", f"{key} must be a list."))
        return []
    return value


def object_items(items, key, issues):
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            issues.append(issue("BLOCKER", "malformedJSON", f"{key}[{index}] must be an object."))
            continue
        yield item


def string_items(items, key, issues):
    for index, item in enumerate(items):
        if not isinstance(item, str):
            issues.append(issue("BLOCKER", "malformedJSON", f"{key}[{index}] must be a string."))
            continue
        yield item


def installed_collision_issue(target: Path, package_id: str) -> dict:
    if target.is_dir():
        target = target / MANIFEST_NAME
    try:
        existing = json.loads(target.read_text(encoding="utf-8"))
        existing_id = existing.get("id") if isinstance(existing, dict) else None
    except (OSError, json.JSONDecodeError):
        existing_id = None

    if existing_id == package_id:
        return issue("BLOCKER", "duplicatePackageID", f"{package_id} is already installed in the development capability library.")
    return issue("BLOCKER", "duplicatePackageFilename", f"{package_id} maps to an installed capability filename already owned by {existing_id or 'an unreadable package'}.")


def discover_package_paths(path):
    if directory_mode:
        if not path.is_dir():
            print(f"BLOCKER unreadableFile: {path} is not a directory", file=sys.stderr)
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
        manifest = path / MANIFEST_NAME
        if manifest.is_file():
            return [manifest]
        print("BLOCKER directoryInput: use validate-dir or install-dev-dir for capability libraries", file=sys.stderr)
        sys.exit(1)
    return [path]


def icon_asset_relative_path(package, issues):
    descriptor = package.get("iconDescriptor")
    if descriptor is None:
        return None
    if not isinstance(descriptor, dict):
        issues.append(issue("BLOCKER", "malformedJSON", "iconDescriptor must be an object."))
        return None
    if descriptor.get("kind") != "asset":
        return None

    value = descriptor.get("value")
    if not isinstance(value, str):
        issues.append(issue("BLOCKER", "invalidIconAsset", "Asset icon value must be a string."))
        return None
    trimmed = value.strip()
    parts = trimmed.split("/")
    invalid = (
        not trimmed
        or "://" in trimmed
        or trimmed.startswith("/")
        or not trimmed.startswith("assets/")
        or any(part in {"", ".", ".."} for part in parts)
        or Path(trimmed).suffix.lower() not in ALLOWED_ICON_EXTENSIONS
    )
    if invalid:
        issues.append(issue("BLOCKER", "invalidIconAsset", "Asset icons must use a relative assets/ path with a pdf, png, or svg extension."))
        return None
    return trimmed


def validate_icon_asset(package, package_root, issues):
    relative = icon_asset_relative_path(package, issues)
    if relative is None:
        return None

    asset = package_root / relative
    try:
        resolved_root = package_root.resolve()
        resolved_asset = asset.resolve()
    except OSError as exc:
        issues.append(issue("BLOCKER", "invalidIconAsset", f"{relative} could not be resolved safely: {exc}"))
        return None
    if resolved_root not in resolved_asset.parents:
        issues.append(issue("BLOCKER", "invalidIconAsset", f"{relative} escapes the capability package."))
        return None
    if not asset.exists():
        issues.append(issue("BLOCKER", "missingIconAsset", f"{relative} was declared but was not found in the package assets."))
        return None
    if not asset.is_file() or asset.is_symlink():
        issues.append(issue("BLOCKER", "invalidIconAsset", f"{relative} must be a regular file."))
        return None
    if asset.stat().st_size > MAX_ICON_BYTES:
        issues.append(issue("BLOCKER", "invalidIconAsset", f"{relative} is larger than {MAX_ICON_BYTES} bytes."))
        return None
    return relative


def validate_package(path: Path) -> dict:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        return {
            "path": path,
            "package": None,
            "package_id": "",
            "safe_name": "",
            "issues": [issue("BLOCKER", "unreadableFile", f"{exc}")],
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
    package_root = path.parent
    if not isinstance(package, dict):
        return {
            "path": path,
            "package": None,
            "package_id": "",
            "safe_name": "",
            "issues": [issue("BLOCKER", "malformedJSON", "Package JSON root must be an object.")],
        }

    raw_package_id = package.get("id", "")
    package_id = raw_package_id.strip() if isinstance(raw_package_id, str) else ""
    safe_name = safe_file_name(package_id)
    if not isinstance(raw_package_id, str) or not package_id:
        issues.append(issue("BLOCKER", "invalidPackageID", "Package ID cannot be empty."))
    elif raw_package_id != package_id or not SAFE_ID.match(package_id):
        issues.append(issue("BLOCKER", "invalidPackageID", "Package ID must start with a letter or number and contain only ASCII letters, numbers, dots, hyphens, and underscores."))

    if safe_name == "capability":
        issues.append(issue("BLOCKER", "invalidPackageID", "Package ID does not produce a usable capability filename."))

    raw_version = package.get("version", "")
    version = raw_version.strip() if isinstance(raw_version, str) else ""
    if not isinstance(raw_version, str) or raw_version != version or not SEMVER.match(version):
        issues.append(issue("BLOCKER", "invalidVersion", f"Package version {version or '<empty>'} is not semantic."))

    if "governance" not in package or package.get("governance") is None:
        issues.append(issue("WARNING", "missingGovernance", "Package will be imported as draft, admin-only, and requiring local review."))
    else:
        governance = package.get("governance")
        if not isinstance(governance, dict):
            issues.append(issue("BLOCKER", "malformedJSON", "governance must be an object."))
        elif governance.get("approvalStatus") != "draft" or governance.get("visibility") != "adminOnly" or governance.get("requiresAdminApproval") is not True:
            issues.append(issue("WARNING", "approvalReset", "Local imports cannot approve themselves; approval will be reset to draft."))

    source = package.get("sourceMetadata")
    if source != {"id": "local", "displayName": "Local Capability Library", "kind": "local", "trustLevel": "local"}:
        issues.append(issue("WARNING", "localSourceNormalized", "Imported package source will be set to local."))

    skills = list_field(package, "skills", issues)
    connectors = list_field(package, "connectors", issues)
    local_tools = list_field(package, "localTools", issues)
    mcp_servers = list_field(package, "mcpServers", issues)
    templates = list_field(package, "templates", issues)
    browser_adapters = list_field(package, "browserAdapters", issues)
    payload_count = sum(len(items) for items in (skills, connectors, local_tools, mcp_servers, templates, browser_adapters))
    if payload_count == 0:
        issues.append(issue("WARNING", "emptyPayload", "Package declares no installable payload."))

    for tool in object_items(local_tools, "localTools", issues):
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

    for connector in object_items(connectors, "connectors", issues):
        credential_hints = connector.get("credentialHints") or []
        if credential_hints and not isinstance(credential_hints, list):
            issues.append(issue("BLOCKER", "malformedJSON", f"{connector.get('name') or 'connector'} credentialHints must be a list."))
            continue
        if not credential_hints:
            continue
        base_url = str(connector.get("baseURL") or "").strip()
        if not base_url:
            continue
        scheme, host = host_from_url(base_url)
        if scheme != "https" and not (scheme == "http" and is_loopback(host)):
            name = str(connector.get("name") or connector.get("serviceType") or "connector")
            issues.append(issue("BLOCKER", "unsafeConnector", f"{name} cannot use credentials over remote cleartext HTTP."))

    for adapter in string_items(browser_adapters, "browserAdapters", issues):
        compact = str(adapter).strip().lower().replace("-", "").replace("_", "").replace(".", "")
        if compact not in KNOWN_BROWSER_ADAPTERS:
            issues.append(issue("BLOCKER", "unknownBrowserAdapter", f"{adapter} is not a known ASTRA browser adapter ID."))

    for server in object_items(mcp_servers, "mcpServers", issues):
        name = str(server.get("displayName") or server.get("id") or "MCP server")
        transport = str(server.get("transport") or "").lower()
        if transport == "stdio":
            command = str(server.get("command") or "").strip()
            raw_args = server.get("arguments") or []
            if not isinstance(raw_args, list):
                issues.append(issue("BLOCKER", "malformedJSON", f"{name} arguments must be a list."))
                raw_args = []
            args = " ".join(str(arg) for arg in raw_args)
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

    icon_asset_path = validate_icon_asset(package, package_root, issues)

    if package_id and install_mode:
        targets = [
            DEV_LIBRARY / f"{safe_name}.json",
            DEV_LIBRARY / safe_name,
        ]
        for target in targets:
            if target.exists():
                issues.append(installed_collision_issue(target, package_id))

    return {
        "path": path,
        "package_root": package_root,
        "package": package,
        "package_id": package_id,
        "safe_name": safe_name,
        "icon_asset_path": icon_asset_path,
        "issues": issues,
    }


def add_batch_collision_issues(results):
    ids = {}
    safe_names = {}
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
    if result["icon_asset_path"]:
        target_dir = DEV_LIBRARY / result["safe_name"]
        target_dir.mkdir(parents=True, exist_ok=True)
        target = target_dir / MANIFEST_NAME
        source_asset = result["package_root"] / result["icon_asset_path"]
        target_asset = target_dir / result["icon_asset_path"]
        target_asset.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_asset, target_asset)
    else:
        target = DEV_LIBRARY / f"{result['safe_name']}.json"
    target.write_text(json.dumps(package, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Installed {result['package_id']} to {target}")
PY
