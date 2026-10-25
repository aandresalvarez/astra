import Testing
import ASTRACore
@testable import ASTRA

@Suite("Prerequisite scan publication")
struct PrerequisiteScanSnapshotTests {
    @Test("The rail cannot report Ready while a declared check is pending")
    func pendingRailReadiness() {
        let prerequisite = CommonCLIPrerequisites.githubAuth
        let package = PluginPackage(id: "pending", name: "Pending", icon: "terminal", description: "Test",
            author: "Tests", category: "Tests", tags: [], version: "1", skills: [], connectors: [],
            localTools: [], templates: [], prerequisites: [prerequisite], governance: .builtInApproved())
        let readiness = CapabilityRailRepair.readiness(for: package, stateReadiness: .ready, prerequisiteStatuses: [:])
        #expect(readiness.level == .needsAttention)
        #expect(readiness.messages.contains { $0.contains("Checking") })
        #expect(CapabilityRailRepair.readiness(for: package, stateReadiness: .inactive, prerequisiteStatuses: [:]) == .inactive)
        #expect(CapabilityRailRepair.readiness(for: package, stateReadiness: .ready,
            prerequisiteStatuses: [prerequisite.id: .healthy(path: "/usr/bin/gh", version: "test")]) == .ready)
    }

    @Test("Refreshing health immediately withdraws the old ready result and ignores stale completions")
    func refreshWithdrawsOldReadiness() {
        var scan = PrerequisiteScanSnapshot()
        let healthy: HealthStatus = .healthy(path: "/opt/homebrew/bin/gh", version: "fixture")
        let first = scan.begin()
        scan.complete(["auth": healthy], generation: first)
        #expect(scan.statuses["auth"]?.isUsable == true)
        let current = scan.begin()
        #expect(scan.statuses.isEmpty)
        scan.complete(["auth": healthy], generation: first)
        #expect(scan.statuses.isEmpty)
        scan.complete(["auth": .unauthenticated(detail: "Signed out")], generation: current)
        #expect(scan.statuses["auth"]?.isUsable == false)
        #expect(scan.statuses["auth"] == .unauthenticated(detail: "Signed out"))
    }

    @Test("A rescan replaces a prior login failure with the new unverified evidence")
    func rescanClearsStaleLoginFailure() {
        let prerequisite = CommonCLIPrerequisites.gcloudAuth
        let package = PluginPackage(id: "gcloud-qa", name: "GCloud", icon: "cloud", description: "Test",
            author: "Tests", category: "Tests", tags: [], version: "1", skills: [], connectors: [],
            localTools: [], templates: [], prerequisites: [prerequisite], governance: .builtInApproved())
        var scan = PrerequisiteScanSnapshot()
        let previous = scan.begin()
        scan.complete([prerequisite.id: .unauthenticated(detail: "No active account")], generation: previous)
        #expect(CapabilityRailRepair.readiness(for: package, stateReadiness: .ready, prerequisiteStatuses: scan.statuses).level == .needsAttention)
        let current = scan.begin()
        #expect(scan.statuses.isEmpty)
        scan.complete([prerequisite.id: .unverified(path: "/opt/homebrew/bin/gcloud", detail: "No answer within 20s")], generation: current)
        scan.complete([prerequisite.id: .unauthenticated(detail: "Old response")], generation: previous)
        #expect(CapabilityRailRepair.readiness(for: package, stateReadiness: .ready, prerequisiteStatuses: scan.statuses) == .ready)
        #expect(CapabilityRailRepair.repair(for: package, statuses: scan.statuses) == nil)
    }
}
