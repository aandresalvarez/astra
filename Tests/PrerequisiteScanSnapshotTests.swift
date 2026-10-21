import Testing
import ASTRACore
@testable import ASTRA

@Suite("Prerequisite scan publication")
struct PrerequisiteScanSnapshotTests {
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
}
