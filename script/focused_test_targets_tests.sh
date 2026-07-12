#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

assert_targets() {
  local expected="$1"
  shift

  local actual
  actual="$(script/focused_test_targets.sh "$@")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'Expected targets:\n%s\nActual targets:\n%s\n' "$expected" "$actual" >&2
    return 1
  fi
}

assert_targets "MCPGatewaySupportTests" \
  "Tools/MCPGatewaySupport/MCPGatewaySupport.swift" \
  "Tests/MCPGatewaySupportTests/RemoteMCPGatewaySupportTests.swift"

assert_targets "MCPServerKitTests" \
  "Tools/MCPServerKit/MCPServerKit.swift" \
  "Tests/MCPServerKitTests/MCPServerKitTests.swift"

assert_targets "MailToolSupportTests" \
  "Tools/MailToolSupport/AppleScriptSource.swift" \
  "Tools/StanfordAppleMailTool/main.swift" \
  "Tests/MailToolSupportTests/StanfordAppleMailToolTests.swift"

assert_targets "HostControlToolSupportTests" \
  "Tools/HostControlToolSupport/HostControlToolSupport.swift" \
  "Tools/AstraHostControlTool/main.swift" \
  "Tests/HostControlToolSupportTests.swift"

assert_targets $'ArchitectureFitnessTests.ArchitectureFitnessTests\nMCPGatewaySupportTests\nMCPServerKitTests\nMailToolSupportTests' \
  "Package.swift"

assert_targets "ArchitectureFitnessTests.ArchitectureFitnessTests" \
  "Tests/ArchitectureFitnessTests/ArchitectureFitnessTests.swift"

assert_targets "AppSemanticFitnessTests" \
  "Tests/AppSemanticFitnessTests.swift"

assert_targets ""

assert_targets "" \
  "Astra/Services/Runtime/AgentRuntimeAdapter.swift"

assert_targets $'ReleaseBuildNumberDerivationTests\nReleaseUpdateScriptTests\nAppBundlePackagingTests' \
  ".github/workflows/release.yml" \
  "script/build_and_run.sh" \
  "Tests/ReleaseBuildNumberDerivationTests.swift"
