import Darwin
import Foundation
import Testing
@testable import ASTRA

@Suite("Controlled Browser profile reservation", .serialized)
struct ControlledBrowserProfileLeaseTests {
    @Test("Runtime status explains a reserved profile without claiming a permission failure")
    func runtimeReservationMessage() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)
        _ = monitor.processEvent(.toolUse(name: "astra-browser", id: "reserved", input: nil), process: nil)
        let stopped = monitor.processEvent(.toolResult(toolId: "reserved",
            content: #"{"ok":false,"error":"controlled_browser_profile_reserved"}"#), process: nil)
        #expect(stopped && monitor.runtimeStopped && !monitor.budgetExceeded)
        #expect(monitor.runtimeStopReason == "controlled_browser_profile_reserved")
        #expect(monitor.runtimeStopMessage?.contains("shared Controlled Browser profile") == true)
        #expect(monitor.runtimeStopMessage?.contains("permissions") == false)
        var response: [String: Any] = [:]
        BrowserBridgeRecoveryHints.attach(to: &response, error: "controlled_browser_profile_reserved")
        #expect((response["recovery"] as? [String: Any])?["kind"] as? String == "wait-for-profile")
    }

    @Test("Ambiguous browser roots cannot be treated as verified absence")
    func ambiguousRoots() throws {
        let first = ControlledBrowserDebugTarget(processID: 1, debugPort: 60001)
        let second = ControlledBrowserDebugTarget(processID: 2, debugPort: 60002)
        #expect(try ControlledBrowserProcessDiscovery.select([]) == nil)
        #expect(try ControlledBrowserProcessDiscovery.select([first]) == first)
        #expect(throws: (any Error).self) { try ControlledBrowserProcessDiscovery.select([first, second]) }
    }

    @Test("Reconnect matches the exact profile argument, including spaces, and only a browser root")
    func exactProcessArguments() {
        let profile = "/tmp/Astra Dev/Profile"
        let executable = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let base = [executable, "--remote-debugging-port=60007"]
        func target(_ extra: [String]) -> ControlledBrowserDebugTarget? {
            ControlledBrowserProcessDiscovery.target(pid: 99935, arguments: base + extra, profilePath: profile)
        }
        #expect(target(["--user-data-dir=\(profile)"]) == ControlledBrowserDebugTarget(processID: 99935, debugPort: 60007))
        #expect(target(["--user-data-dir=\(profile)/independent"]) == nil)
        #expect(target(["--user-data-dir=\(profile) Other"]) == nil)
        #expect(target(["--user-data-dir=\(profile)", "--type=renderer"]) == nil)
        #expect(target(["--user-data-dir=\(profile)", "--user-data-dir=/tmp/other"]) == nil)
        #expect(target(["--user-data-dir=\(profile)", "--remote-debugging-port=60008"]) == nil)
        #expect(ControlledBrowserProcessDiscovery.target(pid: 1,
            arguments: ["/usr/bin/other", "--user-data-dir=\(profile)", "--remote-debugging-port=60007"], profilePath: profile) == nil)
        let override = "/tmp/QA Browser.app/Contents/MacOS/QA Browser"
        let overridden = [override, "--user-data-dir=\(profile)", "--remote-debugging-port=60007"]
        #expect(ControlledBrowserProcessDiscovery.target(pid: 1, arguments: overridden, profilePath: profile) == nil)
        #expect(ControlledBrowserProcessDiscovery.target(pid: 1, arguments: overridden,
            profilePath: profile, allowedExecutables: [override])?.processID == 1)
    }

    @Test("Kernel argv decoding preserves spaces and stops before environment values")
    func decodeKernelArguments() {
        let argv = ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "--user-data-dir=/tmp/Astra Dev/Profile", ""]
        var argc = Int32(argv.count)
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        bytes += Array("/executable\0\0".utf8)
        bytes += Array((argv.joined(separator: "\0") + "\0SHOULD_NOT_DECODE=value\0").utf8)
        #expect(ControlledBrowserProcessDiscovery.decodeArguments(bytes) == argv)
        #expect(ControlledBrowserProcessDiscovery.decodeArguments([0, 0, 0, 0]) == nil)
        #expect(ControlledBrowserProcessDiscovery.decodeArguments(Array(bytes.prefix(10))) == nil)
    }

    @MainActor @Test("A reserved profile is a waiting state and never starts a competing browser")
    func waitingPresentation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var held: ControlledBrowserProfileLease? = try .acquire(profilePath: root.path, owner: "A")
        let competitor = ControlledBrowserController(profilePath: root.path)
        #expect(competitor.bindProfileOwner("B"))
        await competitor.launch(initialAddress: "https://example.com")
        #expect(competitor.runState == .waitingForProfile)
        #expect(!competitor.isRunning)
        #expect(competitor.processID == nil)
        #expect(competitor.statusMessage.contains("Embedded Browser remains available"))
        await competitor.refreshStatus()
        #expect(competitor.runState == .waitingForProfile)
        #expect(competitor.processID == nil)
        #expect(held != nil)
        held = nil
        await competitor.refreshStatus()
        #expect(competitor.runState == .idle)
        #expect(competitor.lastErrorMessage == nil)
    }

    @Test("A profile excludes concurrent controllers but independent profiles continue")
    func exclusivity() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var first: ControlledBrowserProfileLease? = try .acquire(profilePath: root.path, owner: "A")
        #expect(throws: (any Error).self) { try ControlledBrowserProfileLease.acquire(profilePath: root.path, owner: "B") }
        let independent = try ControlledBrowserProfileLease.acquire(profilePath: root.appendingPathComponent("independent").path, owner: "B")
        withExtendedLifetime(independent) {}
        first = nil
        #expect(first == nil)
        let second = try ControlledBrowserProfileLease.acquire(profilePath: root.path, owner: "B")
        #expect(second.receipt.owner == "B")
    }

    @Test("A surviving process reconnects only to its recorded owner after ASTRA releases the kernel lock")
    func restart() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let first = try ControlledBrowserProfileLease.acquire(profilePath: root.path, owner: "A")
            try first.recordProcess(getpid()) // real OS identity; never signalled by this test
            #expect(!first.canStartNewProcess)
        }
        #expect(throws: (any Error).self) { try ControlledBrowserProfileLease.acquire(profilePath: root.path, owner: "B") }
        let reconnected = try ControlledBrowserProfileLease.acquire(profilePath: root.path, owner: "A")
        #expect(reconnected.receipt.process == RuntimeProcessIdentity.read(getpid()))
        #expect(!reconnected.canStartNewProcess)
    }

    @Test("Missing launch proof and corrupt receipts fail closed")
    func uncertain() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let first = try ControlledBrowserProfileLease.acquire(profilePath: root.path, owner: "A")
            try first.beginLaunch()
        }
        #expect(throws: (any Error).self) { try ControlledBrowserProfileLease.acquire(profilePath: root.path, owner: "B") }
        do {
            let original = try ControlledBrowserProfileLease.acquire(profilePath: root.path, owner: "A")
            #expect(!original.canStartNewProcess)
        }
        try Data("corrupt".utf8).write(to: root.appendingPathComponent(".astra-profile-owner.json"))
        #expect(throws: (any Error).self) { try ControlledBrowserProfileLease.acquire(profilePath: root.path, owner: "A") }
    }

    @Test("A reused PID is not the previous process, while live and unknown identities retain protection")
    func stopProof() throws {
        let present = try #require(RuntimeProcessIdentity.read(getpid()))
        #expect(!ControlledBrowserProfileLease.stopped(.init(owner: "A", process: present)))
        let previous = RuntimeProcessIdentity(pid: getpid(), startedSeconds: 0, startedMicroseconds: 0)
        #expect(ControlledBrowserProfileLease.stopped(.init(owner: "A", process: previous)))
        #expect(!ControlledBrowserProfileLease.stopped(.init(owner: "A", unknownProcessID: getpid())))
        #expect(!ControlledBrowserProfileLease.stopped(.init(owner: "A", launchPending: true)))
    }

    @Test("An unknown live PID cannot be replaced by a different reconnect candidate")
    func uncertainReconnect() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let receipt = ControlledBrowserProfileLease.Receipt(owner: "A", unknownProcessID: getpid())
        try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent(".astra-profile-owner.json"))
        let lease = try ControlledBrowserProfileLease.acquire(profilePath: root.path, owner: "A")
        #expect(!lease.acceptsExistingProcess(Int32.max))
        #expect(lease.acceptsExistingProcess(getpid()))
        #expect(throws: (any Error).self) { try lease.recordProcess(Int32.max) }
        #expect(lease.receipt.unknownProcessID == getpid())
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("browser-profile-lease-\(UUID())")
    }
}
