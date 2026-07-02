#!/usr/bin/env bash
set -euo pipefail

selected_targets=()

add_target() {
  local target="$1"
  local selected

  if ((${#selected_targets[@]} > 0)); then
    for selected in "${selected_targets[@]}"; do
      [[ "$selected" == "$target" ]] && return 0
    done
  fi

  selected_targets+=("$target")
}

target_for_path() {
  local path="$1"

  if [[ "$path" == "Package.swift" ]]; then
    add_target "MCPGatewaySupportTests"
    add_target "MailToolSupportTests"
    return
  fi

  case "$path" in
    Tests/MCPGatewaySupportTests/*|Tools/AstraMCPGatewayTool/*|Tools/MCPGatewaySupport/*)
      add_target "MCPGatewaySupportTests"
      ;;
    Tests/MailToolSupportTests/*|Tools/MailToolSupport/*|Tools/StanfordAppleMailTool/*|Tools/StanfordGraphMailTool/*|Tools/StanfordMailTool/*)
      add_target "MailToolSupportTests"
      ;;
  esac
}

for path in "$@"; do
  target_for_path "$path"
done

if ((${#selected_targets[@]} > 0)); then
  printf '%s\n' "${selected_targets[@]}"
fi
