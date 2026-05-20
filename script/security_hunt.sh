#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

run() {
  printf '\n==> %s\n' "$*"
  "$@"
}

run swift test --filter SecurityTests
run swift test --filter AgentPolicyTests
run swift test --filter RunPermissionManifestTests
run swift test --filter IsolationTests
run swift test --filter RuntimeReadinessServiceTests
run swift test --filter AppUpdateTests
run swift test --filter BrowserBridgeSecurityTests
run swift test --filter PluginPackageGovernanceTests
run swift test --filter CapabilityCatalogPolicyTests
run swift test --filter CapabilityApprovalTests
run swift test --filter CapabilityInstallerTests
run swift test --filter CapabilityLibraryTests
run swift test --filter CapabilityUninstallerTests
run swift test --filter CapabilityActivationDisablerTests
run swift test --filter PluginPackageMCPTests
run swift test --filter CapabilityLifecycleResolverTests
run swift test --filter CapabilityRuntimeIntegrityServiceTests
run swift test --filter TaskCapabilityResolverTests
run swift test --filter WorkspacePersistenceTests
run swift test --filter SchemaVersionTests
run swift test --filter WorkspaceImport
run swift test --filter JiraConnectorAuthTests
run swift test --sanitize thread
run swift test --sanitize address
run git diff --check
