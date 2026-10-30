import CryptoKit
import Darwin
import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Physical provider reservation identity", .serialized)
@MainActor
struct ProviderSharedStateIdentityTests {
    @Test("HFS+ rejects Unicode components before profile paths can be folded", arguments: [
        "/Profiles/Straße", "/Profiles/caf\u{00e9}", "/Profiles/cafe\u{0301}"
    ])
    func hfsUnicodeComponents(path: String) throws {
        do {
            try ProviderSharedStateIdentity.validateSupportedComponents(path) { _ in "hfs" }
            Issue.record("A Unicode HFS+ profile was accepted")
        } catch let failure as ProviderSharedStateIdentity.Failure {
            #expect(failure.localizedDescription.contains("HFS+"))
            #expect(failure.localizedDescription.contains("APFS"))
            #expect(failure.localizedDescription.contains("ASCII-only"))
            #expect(failure.localizedDescription.contains("preserved"))
        }
    }

    @Test("ASCII HFS+ and Unicode APFS or case-sensitive filesystems remain supported")
    func supportedFileSystemComponents() throws {
        try ProviderSharedStateIdentity.validateSupportedComponents("/Profiles/ASCII/settings.json") { _ in "hfs" }
        for type in ["apfs", "ufs"] {
            try ProviderSharedStateIdentity.validateSupportedComponents("/Profiles/Straße/caf\u{00e9}/settings.json") { _ in type }
        }
    }

    @Test("Filesystem guards follow each parent across mounts and missing tails")
    func mixedFileSystemComponents() throws {
        // The later APFS mount cannot make its Unicode HFS+ ancestor safe.
        #expect(throws: ProviderSharedStateIdentity.Failure.self) {
            try ProviderSharedStateIdentity.validateSupportedComponents("/HFS/Profilé/APFS/settings.json") { parent in
                parent == "/" || parent == "/HFS/Profilé/APFS" ? "apfs" : "hfs"
            }
        }
        // This mount's own name belongs to APFS; only its children belong to HFS+.
        try ProviderSharedStateIdentity.validateSupportedComponents("/HFSé/ASCII/settings.json") { parent in
            parent == "/" ? "apfs" : "hfs"
        }
        #expect(throws: ProviderSharedStateIdentity.Failure.self) {
            try ProviderSharedStateIdentity.validateSupportedComponents("/HFS/Missing/Profilé/settings.json") { parent in
                switch parent {
                case "/": "apfs"
                case "/HFS": "hfs"
                default: nil
                }
            }
        }
        try ProviderSharedStateIdentity.validateSupportedComponents("/APFS/Missing/Profilé/settings.json") { parent in
            parent == "/" || parent == "/APFS" ? "apfs" : nil
        }
    }

    @Test("Real HFS+ Unicode rejection preserves both distinct profiles",
          .enabled(if: ProcessInfo.processInfo.environment["ASTRA_PROVIDER_IDENTITY_HFS_ROOT"] != nil))
    func realHfsUnicodeProfilesStayUntouched() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ASTRA_PROVIDER_IDENTITY_HFS_ROOT"]))
        var volume = statfs()
        try #require(statfs(root.path, &volume) == 0)
        let type = withUnsafeBytes(of: volume.f_fstypename) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        try #require(type == "hfs")
        let fixture = root.appendingPathComponent("provider-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let first = fixture.appendingPathComponent("Straße")
        let second = fixture.appendingPathComponent("Strasse")
        let settings = [first, second].map { AntigravityCLIRuntime.settingsURL(providerHomeDirectory: $0.path) }
        for (index, file) in settings.enumerated() {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{\"profile\":\(index)}".utf8).write(to: file)
        }
        let alias = fixture.appendingPathComponent("ascii-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        var firstInfo = stat(), secondInfo = stat()
        try #require(stat(first.path, &firstInfo) == 0 && stat(second.path, &secondInfo) == 0)
        try #require(firstInfo.st_ino != secondInfo.st_ino)
        let contents = try settings.map { try Data(contentsOf: $0) }
        let names = try FileManager.default.subpathsOfDirectory(atPath: fixture.path).sorted()
        #expect(throws: ProviderSharedStateIdentity.Failure.self) {
            try ProviderSharedStateIdentity.providerHome(first.path)
        }
        #expect(throws: ProviderSharedStateIdentity.Failure.self) {
            try ProviderSharedStateIdentity.providerHome(alias.path)
        }
        #expect(throws: ProviderSharedStateIdentity.Failure.self) {
            try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: settings[0])
        }
        let missing = fixture.appendingPathComponent("Missingé/.gemini/settings.json")
        #expect(throws: ProviderSharedStateIdentity.Failure.self) {
            try ProviderSharedStateIdentity.canonicalPath(missing.path)
        }
        _ = try ProviderSharedStateIdentity.providerHome(second.path)
        #expect(try settings.map { try Data(contentsOf: $0) } == contents)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: fixture.path).sorted() == names)
        var finalFirstInfo = stat(), finalSecondInfo = stat()
        #expect(stat(first.path, &finalFirstInfo) == 0 && stat(second.path, &finalSecondInfo) == 0)
        #expect(finalFirstInfo.st_ino == firstInfo.st_ino && finalSecondInfo.st_ino == secondInfo.st_ino)
    }

    @Test("Canonical Unicode equivalents share a kernel lock and legacy hashes stay unchanged")
    func unicodeKernelIdentity() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let root = h.rootURL.appendingPathComponent("unicode-locks")
        let composed = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: "file-v1:\(h.rootURL.path)/missing/caf\u{00e9}/settings.json")
        let decomposed = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: "file-v1:\(h.rootURL.path)/missing/cafe\u{0301}/settings.json")
        #expect(composed == decomposed)
        #expect(Array(composed.rawValue.utf8) != Array(decomposed.rawValue.utf8))
        let held = try await ProviderSharedStateProcessLock.acquire(composed, root: root)
        defer { withExtendedLifetime(held) {} }
        do {
            _ = try await ProviderSharedStateProcessLock.acquire(decomposed, root: root,
                deadline: ContinuousClock.now.advanced(by: .milliseconds(50)))
            Issue.record("Unicode-equivalent profile bypassed the kernel lock")
        } catch is RuntimeProviderStateWaitTimeout {}
        let legacy = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: "old/cafe\u{0301}")
        let oldRoot = h.rootURL.appendingPathComponent("legacy-hash")
        let old = try await ProviderSharedStateProcessLock.acquire(legacy, root: oldRoot)
        let expected = SHA256.hash(data: Data(legacy.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(FileManager.default.fileExists(atPath: oldRoot.appendingPathComponent(expected).path))
        withExtendedLifetime(old) {}
    }

    @Test("Unsafe legacy locks report the blocking path without changing the reservation", arguments: ["symlink", "public", "hardlink"])
    func unsafeLegacyDiagnostic(kind: String) async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let root = h.rootURL.appendingPathComponent("unsafe-locks")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = root.appendingPathComponent(String(repeating: "a", count: 64))
        let target = h.rootURL.appendingPathComponent("target-lock")
        try Data("protected".utf8).write(to: target)
        if kind == "symlink" { try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target) }
        else if kind == "hardlink" { try FileManager.default.linkItem(at: target, to: lock) }
        else { try Data("protected".utf8).write(to: lock); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lock.path) }
        let key = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: h.rootURL.appendingPathComponent("profile/settings.json"))
        do { _ = try await ProviderSharedStateProcessLock.acquire(key, root: root); Issue.record("Unsafe legacy lock admitted") }
        catch let failure as ProviderSharedStateCompatibility.UnreadableReservation {
            #expect(failure.localizedDescription.contains(lock.path))
        }
        #expect(try Data(contentsOf: target) == Data("protected".utf8))
        #expect(FileManager.default.fileExists(atPath: lock.path))
    }

    @Test("Case-insensitive mounts preserve case-sensitive ancestor names")
    func nestedVolumeSensitivity() throws {
        #expect(try ProviderSharedStateIdentity.normalizedComponents("/Profiles/Mount/Config/New/File") { parent in
            switch parent {
            case "/", "/Profiles": true
            case "/Profiles/Mount", "/Profiles/Mount/Config": false
            default: nil
            }
        } == "/Profiles/Mount/config/new/file")
    }
    @Test("Profile aliases share a key before and after settings creation")
    func aliasesAndCreation() throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let home = h.rootURL.appendingPathComponent("profile")
        let alias = h.rootURL.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: home)
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Synthetic", model: "test")
        func key(_ home: URL) throws -> AgentRuntimeSharedStateKey? {
            try AgentRuntimeAdapterRegistry.adapter(for: .antigravityCLI).sharedLaunchStateKey(context: .init(
                prompt: "Synthetic", task: task, workspacePath: h.workspaceURL.path, executablePath: "/usr/bin/false",
                providerHomeDirectory: home.path, permissionPolicy: .restricted, executionPolicy: .default,
                permissionManifest: nil, timeoutSeconds: 10))
        }
        let before = try key(home)
        #expect(try key(alias) == before)
        let settings = AntigravityCLIRuntime.settingsURL(providerHomeDirectory: home.path)
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: settings, options: .atomic)
        #expect(try key(alias) == before)
        #expect(try key(home) == before)
    }

    @Test("Physical resolution respects symlinks before dot-dot and stable atomic replacement")
    func physicalResolution() throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let target = h.rootURL.appendingPathComponent("target/nested")
        let alias = h.rootURL.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let path = alias.path + "/../settings.json"
        let expected = try ProviderSharedStateIdentity.canonicalPath(target.deletingLastPathComponent().path + "/settings.json")
        #expect(try ProviderSharedStateIdentity.canonicalPath(path) == expected)
        let url = URL(fileURLWithPath: expected)
        let before = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: url)
        try Data("{}".utf8).write(to: url, options: .atomic)
        try Data("{\"model\":\"new\"}".utf8).write(to: url, options: .atomic)
        #expect(try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: url) == before)
        #expect(try ProviderSharedStateIdentity.canonicalPath("/tmp") == ProviderSharedStateIdentity.canonicalPath("/private/tmp"))
        let sensitive = try h.rootURL.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
        if sensitive == false {
            #expect(try ProviderSharedStateIdentity.canonicalPath(url.path.uppercased()) == expected)
        }
    }

    @Test("Hard links and dangling links cannot claim a reliable file identity")
    func unsupportedLinks() throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let first = h.rootURL.appendingPathComponent("settings.json")
        let other = h.rootURL.appendingPathComponent("other.json")
        try Data("{}".utf8).write(to: first)
        try FileManager.default.linkItem(at: first, to: other)
        #expect(throws: ProviderSharedStateIdentity.Failure.self) { try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: first) }
        let dangling = h.rootURL.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: h.rootURL.appendingPathComponent("absent"))
        #expect(throws: ProviderSharedStateIdentity.Failure.self) { try ProviderSharedStateIdentity.canonicalPath(dangling.path + "/settings.json") }
    }

    @Test("Independent gates serialize aliases, while a different profile can run")
    func kernelExclusion() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let alias = h.rootURL.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: h.workspaceURL)
        let key = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: h.workspaceURL.appendingPathComponent("settings.json"))
        let equivalent = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: alias.appendingPathComponent("settings.json"))
        let independent = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: h.rootURL.appendingPathComponent("other/settings.json"))
        let root = h.rootURL.appendingPathComponent("locks")
        let one = AgentRuntimeSharedStateGate(processLockRoot: root, registeredStoreRoots: [])
        let two = AgentRuntimeSharedStateGate(processLockRoot: root, registeredStoreRoots: [])
        let held = try await one.acquire(key)
        do { _ = try await two.acquire(equivalent, timeoutSeconds: 0.05); Issue.record("Alias bypassed kernel ownership") }
        catch is RuntimeProviderStateWaitTimeout {}
        let parallel = try await two.acquire(independent)
        await two.release(parallel)
        #expect(await one.isHeld(held))
        await one.release(held)
        let successor = try await two.acquire(equivalent)
        #expect(await two.release(successor))
        #expect(await two.release(successor) == false)
    }

    @Test("An anonymous live legacy lock survives timeout and cancellation")
    func legacyKernelLock() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let root = h.rootURL.appendingPathComponent("locks")
        let legacy = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: "unknown-old-alias")
        let key = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: h.rootURL.appendingPathComponent("settings.json"))
        var holder: ProviderSharedStateProcessLock? = try await ProviderSharedStateProcessLock.acquire(legacy, root: root)
        let gate = AgentRuntimeSharedStateGate(processLockRoot: root, registeredStoreRoots: [])
        do { _ = try await gate.acquire(key, timeoutSeconds: 0.05); Issue.record("Legacy lock was bypassed") }
        catch is RuntimeProviderStateWaitTimeout {}
        let entered = AgentLockedBuffer()
        let waiting = Task {
            try await ProviderSharedStateCompatibility.waitForLegacyLocks(in: root, deadline: nil,
                onContention: { entered.append("waiting") })
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while entered.value.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!entered.value.isEmpty)
        waiting.cancel()
        do { _ = try await waiting.value; Issue.record("Cancelled legacy wait acquired") } catch is CancellationError {}
        withExtendedLifetime(holder) {}
        holder = nil
        let successor = try await gate.acquire(key)
        await gate.release(successor)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.count == 64 }.count == 1)
    }

    @Test("A redirected settings directory is rejected before adapter mutation")
    func retargetedDirectory() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let first = h.rootURL.appendingPathComponent("first")
        let second = h.rootURL.appendingPathComponent("second")
        let link = h.workspaceURL.appendingPathComponent(".gemini")
        for url in [first, second] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let task = h.makeTask(runtime: .antigravityCLI, goal: "No mutation", model: "test")
        var context = AgentRuntimeProcessLaunchContext(prompt: "Synthetic", task: task, workspacePath: h.workspaceURL.path,
            executablePath: "/usr/bin/false", providerHomeDirectory: h.workspaceURL.path, permissionPolicy: .restricted,
            executionPolicy: .default, permissionManifest: nil, timeoutSeconds: 10)
        let adapter = AgentRuntimeAdapterRegistry.adapter(for: .antigravityCLI)
        context.sharedStateKey = try adapter.sharedLaunchStateKey(context: context)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        let runner = AgentRuntimeProcessRunner { _ in .init(enforcement: .off) }
        let outcome = await runner.guardedSandboxedPlan(adapter: adapter, context: context,
            homeAccessCheck: { _, _ in Issue.record("Redirected provider reached preflight"); return nil })
        guard case .blocked(let result) = outcome else { Issue.record("Redirected provider got a plan"); return }
        #expect(result.runtimeStopReason == RuntimeProviderResourceRegistry.Block.stopReason)
        for url in [first, second] {
            #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("antigravity-cli/settings.json").path))
        }
    }

    @Test("Writing through the reserved target preserves a settings symlink")
    func atomicWritePreservesLink() throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let file = h.rootURL.appendingPathComponent("actual.json")
        let link = h.rootURL.appendingPathComponent("settings.json")
        try Data("{\"existing\":true}".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let key = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: link)
        #expect(AntigravityCLIRuntime.applySelectedModel("qa-model", settingsURL: URL(fileURLWithPath: try #require(key.filePath))))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == file.path)
        try key.validate(fileURL: link)
        let data = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(data?["model"] as? String == "qa-model" && data?["existing"] as? Bool == true)
    }

    @Test("Utilities wait on the task's physical reservation before modifying settings")
    func utilitySharesTaskGate() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let alias = h.rootURL.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: h.workspaceURL)
        let settings = AntigravityCLIRuntime.settingsURL(providerHomeDirectory: h.workspaceURL.path)
        let key = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: settings)
        let held = try await AgentRuntimeSharedStateGate.shared.acquire(key)
        var providers = AgentRuntimeProviderSettings()
        providers.setHomeDirectory(alias.path, for: .antigravityCLI)
        providers.setExecutablePath("/usr/bin/false", for: .antigravityCLI)
        let configuration = AgentUtilityRuntimeConfiguration(runtime: .antigravityCLI, model: "test", providerSettings: providers)
        let waiting = Task { await AntigravityCLIRuntimeAdapter().runUtilityPrompt("Synthetic", workspacePath: h.workspaceURL.path,
            configuration: configuration, toolMode: .none) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await AgentRuntimeSharedStateGate.shared.queuedWaiterCount(for: key) == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await AgentRuntimeSharedStateGate.shared.queuedWaiterCount(for: key) == 1)
        waiting.cancel()
        let result = await waiting.value
        #expect(result.error.contains("cancelled"))
        #expect(!FileManager.default.fileExists(atPath: settings.path))
        #expect(await AgentRuntimeSharedStateGate.shared.isHeld(held))
        await AgentRuntimeSharedStateGate.shared.release(held)
    }
}
