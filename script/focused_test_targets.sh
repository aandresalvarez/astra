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
    add_target "ArchitectureFitnessTests.ArchitectureFitnessTests"
    add_target "MCPGatewaySupportTests"
    add_target "MCPServerKitTests"
    add_target "MailToolSupportTests"
    return
  fi

  case "$path" in
    Tests/ArchitectureFitnessTests/*)
      add_target "ArchitectureFitnessTests.ArchitectureFitnessTests"
      ;;
    Tests/AppSemanticFitnessTests.swift)
      add_target "AppSemanticFitnessTests"
      ;;
    Tests/MCPGatewaySupportTests/*|Tools/AstraMCPGatewayTool/*|Tools/MCPGatewaySupport/*)
      add_target "MCPGatewaySupportTests"
      ;;
    Tests/MCPServerKitTests/*|Tools/MCPServerKit/*)
      add_target "MCPServerKitTests"
      ;;
    Tests/MailToolSupportTests/*|Tools/MailToolSupport/*|Tools/StanfordAppleMailTool/*|Tools/StanfordGraphMailTool/*|Tools/StanfordMailTool/*)
      add_target "MailToolSupportTests"
      ;;
    Tests/HostControlToolSupportTests.swift|Tools/AstraHostControlTool/*|Tools/HostControlToolSupport/*)
      add_target "HostControlToolSupportTests"
      ;;
    .github/workflows/release.yml|script/build_and_run.sh|Tests/ReleaseBuildNumberDerivationTests.swift)
      # These three paths co-derive/co-verify the release build-number
      # scheme (PR #253 review comment 3549627108): release.yml's
      # "Determine release version and build" step and
      # default_app_build() in build_and_run.sh must stay byte-for-byte
      # in sync, and ReleaseBuildNumberDerivationTests reads both files
      # fresh from disk to prove it. Both required gates
      # (script/prepush.sh, which this file feeds, and the release
      # workflow's own "Run release test gate" step, which also runs
      # prepush.sh) would otherwise be able to skip this regression suite
      # entirely on a change to any of the three. AppBundlePackagingTests
      # also reads build_and_run.sh directly, so pull it in alongside the
      # other release-path suite for the same reason.
      add_target "ReleaseBuildNumberDerivationTests"
      add_target "ReleaseUpdateScriptTests"
      add_target "AppBundlePackagingTests"
      ;;
  esac
}

for path in "$@"; do
  target_for_path "$path"
done

if ((${#selected_targets[@]} > 0)); then
  printf '%s\n' "${selected_targets[@]}"
fi
