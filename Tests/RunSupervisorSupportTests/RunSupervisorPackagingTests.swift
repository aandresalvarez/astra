import Foundation
import Testing

@Suite("Run supervisor packaging")
struct RunSupervisorPackagingTests {
    @Test("production bundle stages the supervisor while test broker remains excluded")
    func supervisorPackagingAllowlist() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"))
        let buildScript = try String(contentsOf: root.appendingPathComponent("script/build_and_run.sh"))

        #expect(package.contains(#".executable(name: "astra-run-supervisor""#))
        #expect(package.contains(#"path: "Tools/AstraRunSupervisor""#))
        #expect(buildScript.contains(#""astra-run-supervisor""#))
        #expect(package.contains(#"path: "Tests/RunSupervisorBrokerHarness""#))
        #expect(!buildScript.contains("astra-run-supervisor-broker-harness"))
    }
}
