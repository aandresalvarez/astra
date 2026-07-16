import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Read-only input enforcement boundary")
struct ReadOnlyInputEnforcementBoundaryTests {
    @Test("Contract derives every typed read grant and rejects missing or conflicting resources")
    func contractOwnsEveryReadGrant() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("astra-read-contract-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let input = workspace.appendingPathComponent("input.txt")
        let approvedRead = root.appendingPathComponent("approved.txt")
        let credentialRead = root.appendingPathComponent("gitconfig")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "input".write(to: input, atomically: true, encoding: .utf8)
        try "approved".write(to: approvedRead, atomically: true, encoding: .utf8)
        try "credential".write(to: credentialRead, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: root) }

        let grants = [
            RuntimePathGrant(path: workspace.path, access: .readWrite, source: .workspace, reason: "workspace", sensitivity: .normal, lifetime: .workspace, exists: true),
            RuntimePathGrant(path: input.path, access: .read, source: .taskInput, reason: "input", sensitivity: .normal, lifetime: .run, exists: true),
            RuntimePathGrant(path: approvedRead.path, access: .read, source: .sandboxApproval, reason: "approval", sensitivity: .normal, lifetime: .run, exists: true),
            RuntimePathGrant(path: credentialRead.path, access: .read, source: .gitCredential, reason: "credential", sensitivity: .credential, lifetime: .run, exists: true)
        ]
        let contract = ReadOnlyResourceContract(grants: grants)

        #expect(contract.isValid)
        // Credential-bearing read grants (`.gitCredential`) are NOT read-only
        // inputs: they must be excluded from the contract so they can never be
        // forced into agent-readable container input mounts. Task inputs and
        // sandbox approvals remain.
        #expect(Set(contract.paths) == Set([input.path, approvedRead.path].compactMap(ExecutionSandbox.canonicalize)))
        #expect(contract.resources.flatMap(\.sources).contains(.taskInput))
        #expect(contract.resources.flatMap(\.sources).contains(.sandboxApproval))
        #expect(!contract.resources.flatMap(\.sources).contains(.gitCredential))

        let hardLinkAlias = root.appendingPathComponent("hard-link-alias.txt")
        try fm.linkItem(at: input, to: hardLinkAlias)
        let hardLinked = ReadOnlyResourceContract(grants: [
            RuntimePathGrant(path: input.path, access: .read, source: .taskInput, reason: "input", sensitivity: .normal, lifetime: .run, exists: true)
        ])
        #expect(!hardLinked.isValid)
        #expect(hardLinked.failures.contains { if case .multipleHardLinks = $0 { true } else { false } })

        let missing = ReadOnlyResourceContract(grants: [
            RuntimePathGrant(path: root.appendingPathComponent("missing").path, access: .read, source: .taskInput, reason: "missing", sensitivity: .normal, lifetime: .run, exists: false)
        ])
        #expect(!missing.isValid)
        #expect(missing.failures.contains { if case .missingPath = $0 { true } else { false } })

        let conflict = ReadOnlyResourceContract(grants: [
            RuntimePathGrant(path: workspace.path, access: .read, source: .taskInput, reason: "directory input", sensitivity: .normal, lifetime: .run, exists: true),
            RuntimePathGrant(path: input.path, access: .readWrite, source: .workspace, reason: "nested output", sensitivity: .normal, lifetime: .workspace, exists: true)
        ])
        #expect(!conflict.isValid)
        #expect(conflict.failures.contains { if case .writableDescendant = $0 { true } else { false } })
    }

    @Test("Credential and non-input read grants never enter the read-only input contract")
    func contractExcludesCredentialAndNonInputGrants() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("astra-read-contract-excl-\(UUID().uuidString)")
        let input = root.appendingPathComponent("input.txt")
        let sshKey = root.appendingPathComponent("id_ed25519")
        let gitConfig = root.appendingPathComponent("gitconfig")
        let remoteRoot = root.appendingPathComponent("remote", isDirectory: true)
        let connectorFile = root.appendingPathComponent("connector.json")
        try fm.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
        try "input".write(to: input, atomically: true, encoding: .utf8)
        try "key".write(to: sshKey, atomically: true, encoding: .utf8)
        try "config".write(to: gitConfig, atomically: true, encoding: .utf8)
        try "connector".write(to: connectorFile, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: root) }

        let contract = ReadOnlyResourceContract(grants: [
            RuntimePathGrant(path: input.path, access: .read, source: .taskInput, reason: "input", sensitivity: .normal, lifetime: .run, exists: true),
            RuntimePathGrant(path: sshKey.path, access: .read, source: .gitCredential, reason: "ssh identity", sensitivity: .credential, lifetime: .run, exists: true),
            RuntimePathGrant(path: gitConfig.path, access: .read, source: .gitCredential, reason: "git config", sensitivity: .credential, lifetime: .run, exists: true),
            RuntimePathGrant(path: remoteRoot.path, access: .read, source: .remoteWorkspace, reason: "remote", sensitivity: .normal, lifetime: .run, exists: true),
            RuntimePathGrant(path: connectorFile.path, access: .read, source: .connector, reason: "connector", sensitivity: .normal, lifetime: .run, exists: true)
        ])

        // Only the user-selected task input is a read-only input; credential,
        // remote-workspace, and connector read grants must be absent so they are
        // never passed as `additionalReadOnlyInputPaths` to container mounting.
        #expect(Set(contract.paths) == Set([input.path].compactMap(ExecutionSandbox.canonicalize)))
        let sources = Set(contract.resources.flatMap(\.sources))
        #expect(sources == [.taskInput])
        #expect(!sources.contains(.gitCredential))
        #expect(!sources.contains(.remoteWorkspace))
        #expect(!sources.contains(.connector))
    }

    @Test("Directory contracts reject descendant files with writable hard-link aliases")
    func directoryContractRejectsDescendantHardLinkAlias() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("astra-read-directory-hard-link-\(UUID().uuidString)")
        let inputDirectory = root.appendingPathComponent("input", isDirectory: true)
        let nestedDirectory = inputDirectory.appendingPathComponent("nested", isDirectory: true)
        let protectedFile = nestedDirectory.appendingPathComponent("data.txt")
        let writableAlias = root.appendingPathComponent("writable-alias.txt")
        try fileManager.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try "protected".write(to: protectedFile, atomically: true, encoding: .utf8)
        try fileManager.linkItem(at: protectedFile, to: writableAlias)
        defer { try? fileManager.removeItem(at: root) }

        let contract = ReadOnlyResourceContract(grants: [
            RuntimePathGrant(path: inputDirectory.path, access: .read, source: .taskInput, reason: "directory input", sensitivity: .normal, lifetime: .run, exists: true)
        ])

        #expect(!contract.isValid)
        #expect(contract.failures.contains {
            if case .multipleHardLinks(let path, let count) = $0 {
                return ExecutionSandbox.canonicalize(path) == ExecutionSandbox.canonicalize(protectedFile.path)
                    && count > 1
            }
            return false
        })
    }

    @Test("A single unreadable entry does not fail the directory contract closed")
    func directoryContractSkipsUnreadableEntries() throws {
        // Root bypasses POSIX permission checks, so this scenario cannot be
        // constructed as root; skip rather than assert a false result.
        try #require(getuid() != 0, "requires a non-root user to enforce 0o000 perms")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("astra-read-unreadable-\(UUID().uuidString)")
        let inputDirectory = root.appendingPathComponent("input", isDirectory: true)
        let readable = inputDirectory.appendingPathComponent("readable.txt")
        let locked = inputDirectory.appendingPathComponent("locked", isDirectory: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try "readable".write(to: readable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: root)
        }

        let contract = ReadOnlyResourceContract(grants: [
            RuntimePathGrant(path: inputDirectory.path, access: .read, source: .taskInput, reason: "directory input", sensitivity: .normal, lifetime: .run, exists: true)
        ])

        // The unreadable subdirectory must not abort the scan or invalidate the
        // contract: the read-only enforcement covers the whole declared root
        // regardless of what the scan could descend into.
        #expect(contract.isValid)
        #expect(!contract.failures.contains { if case .directoryScanFailed = $0 { true } else { false } })
    }

    @Test("Container proof rejects writable aliases and mixed execution requires both surfaces")
    func containerAliasesAndMixedSurfacesAreVerified() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("astra-read-alias-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let input = workspace.appendingPathComponent("input.txt")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "input".write(to: input, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: root) }

        let contract = ReadOnlyResourceContract(grants: [
            RuntimePathGrant(path: workspace.path, access: .readWrite, source: .workspace, reason: "workspace", sensitivity: .normal, lifetime: .workspace, exists: true),
            RuntimePathGrant(path: input.path, access: .read, source: .userAttachment, reason: "attachment", sensitivity: .normal, lifetime: .run, exists: true)
        ])
        let environment = WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Test",
            image: "astra/test:latest",
            providerPlacement: .host
        )
        let boundary = ReadOnlyInputEnforcementBoundary(contract: contract, executionEnvironment: environment)
        #expect(boundary.mode == .hostSeatbeltAndContainerReadOnlyMounts)

        var mounts = [
            ExecutionEnvironmentMount(hostPath: workspace.path, containerPath: "/workspace", access: .readWrite, role: .workspace),
            ExecutionEnvironmentMount(hostPath: input.path, containerPath: "/workspace/input.txt", access: .readOnly, role: .additionalPath),
            ExecutionEnvironmentMount(hostPath: workspace.path, containerPath: "/host-workspace", access: .readWrite, role: .additionalPath)
        ]
        #expect(boundary.unprotectedContainerPaths(in: mounts) == [try #require(ExecutionSandbox.canonicalize(input.path))])

        mounts.append(ExecutionEnvironmentMount(
            hostPath: input.path,
            containerPath: "/host-workspace/input.txt",
            access: .readOnly,
            role: .additionalPath
        ))
        #expect(boundary.unprotectedContainerPaths(in: mounts).isEmpty)
        #expect(boundary.receipt(appliedSurfaces: [.hostSeatbelt], mounts: mounts) == nil)
        let receipt = try #require(boundary.receipt(
            appliedSurfaces: [.hostSeatbelt, .workspaceContainer],
            mounts: mounts
        ))
        #expect(receipt.protects(input.path))
        #expect(receipt.protects("/host-workspace/input.txt"))

        let encodedEvidence = try JSONEncoder().encode(receipt.evidence)
        let decodedEvidence = try JSONDecoder().decode(ReadOnlyBoundaryEvidence.self, from: encodedEvidence)
        #expect(decodedEvidence == receipt.evidence)
        #expect(decodedEvidence.status == .applied)
        #expect(decodedEvidence.resourceCount == 1)
    }

    @Test("Host inputs force strict wrapping without changing the read scope")
    func hostInputsForceStrictWrapping() {
        let boundary = ReadOnlyInputEnforcementBoundary(
            paths: ["/tmp/attached.pdf"],
            executionEnvironment: .host
        )
        let base = ExecutionSandboxResolution(
            storedEnforcement: .off,
            effectiveSettings: ExecutionSandboxSettings(
                enforcement: .off,
                wrappedRuntimes: [],
                allowNetwork: true,
                readScope: .open
            ),
            reason: nil
        )

        let resolved = boundary.enforcingHostBoundary(in: base, runtime: .cursorCLI)

        #expect(boundary.mode == .hostSeatbelt)
        #expect(resolved.storedEnforcement == .off)
        #expect(resolved.effectiveSettings.enforcement == .strict)
        #expect(resolved.effectiveSettings.readScope == .open)
        #expect(resolved.effectiveSettings.shouldWrap(runtime: .cursorCLI))
        #expect(resolved.reason == .readOnlyInputBoundary)

        let container = ReadOnlyInputEnforcementBoundary(
            paths: ["/tmp/attached.pdf"],
            executionEnvironment: WorkspaceExecutionEnvironment(
                id: "image:test",
                kind: .dockerImage,
                displayName: "Test",
                image: "astra/test:latest",
                providerPlacement: .container
            )
        )
        #expect(container.mode == .containerReadOnlyMounts)
        #expect(container.enforcingHostBoundary(in: base, runtime: .cursorCLI) == base)
    }

    @Test("Seatbelt protects inputs from indirect mutation while preserving scratch writes")
    func seatbeltProtectsInputsFromIndirectMutation() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }

        let base = fm.temporaryDirectory.appendingPathComponent("astra-input-boundary-\(UUID().uuidString)")
        let workspace = base.appendingPathComponent("workspace")
        let attachmentDirectory = workspace.appendingPathComponent("inputs")
        let protectedDirectory = workspace.appendingPathComponent("input-directory")
        let protectedFile = attachmentDirectory.appendingPathComponent("attached.txt")
        let protectedArchive = attachmentDirectory.appendingPathComponent("attached.zip")
        let scratchFile = workspace.appendingPathComponent("scratch.txt")
        try fm.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: protectedDirectory, withIntermediateDirectories: true)
        try "attachment".write(to: protectedFile, atomically: true, encoding: .utf8)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = attachmentDirectory
        zip.arguments = ["-q", protectedArchive.path, protectedFile.lastPathComponent]
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)
        let originalArchive = try Data(contentsOf: protectedArchive)
        defer { try? fm.removeItem(at: base) }

        let workspaceRoot = try #require(ExecutionSandbox.canonicalize(workspace.path))
        let attachmentDirectoryRoot = try #require(ExecutionSandbox.canonicalize(attachmentDirectory.path))
        let fileRoot = try #require(ExecutionSandbox.canonicalize(protectedFile.path))
        let archiveRoot = try #require(ExecutionSandbox.canonicalize(protectedArchive.path))
        let directoryRoot = try #require(ExecutionSandbox.canonicalize(protectedDirectory.path))
        let profile = ExecutionSandbox.makeProfile(
            writableRootCount: 1,
            protectedWriteDenyRootCount: 3,
            protectedWriteAncestorDenyRootCount: 2,
            allowNetwork: true,
            readScope: .open
        )
        let protectedRoots = [fileRoot, archiveRoot, directoryRoot]
        let protectedAncestorRoots = [attachmentDirectoryRoot, workspaceRoot]
        let run: (String) -> Int32 = { script in
            runConfined(
                profile: profile,
                writableRoots: [workspaceRoot],
                protectedWriteDenyRoots: protectedRoots,
                protectedWriteAncestorDenyRoots: protectedAncestorRoots,
                script: script
            )
        }

        #expect(run("cat '\(protectedFile.path)' >/dev/null && printf ok > '\(scratchFile.path)'") == 0)
        #expect((try? String(contentsOf: scratchFile, encoding: .utf8)) == "ok")

        // Exact PR #315 workflow: scratch cleanup and extraction are allowed,
        // while the attached archive itself stays immutable.
        let inspectDirectory = workspace.appendingPathComponent("dcq_inspect")
        #expect(run("cd '\(workspace.path)' && rm -rf dcq_inspect && mkdir dcq_inspect && cd dcq_inspect && /usr/bin/unzip -q '\(protectedArchive.path)'") == 0)
        #expect(fm.fileExists(atPath: inspectDirectory.appendingPathComponent("attached.txt").path))
        #expect(try Data(contentsOf: protectedArchive) == originalArchive)
        #expect(run("rm -f '\(protectedFile.path)'") != 0)
        #expect(run("/bin/bash -c 'rm -f \"$0\"' '\(protectedFile.path)'") != 0)
        let hardLinkAlias = workspace.appendingPathComponent("attached-alias.txt")
        #expect(run("ln '\(protectedFile.path)' '\(hardLinkAlias.path)' && printf changed > '\(hardLinkAlias.path)'") != 0)
        #expect((try? String(contentsOf: protectedFile, encoding: .utf8)) == "attachment")

        let movedAttachmentDirectory = workspace.appendingPathComponent("moved-inputs")
        #expect(run("mv '\(attachmentDirectory.path)' '\(movedAttachmentDirectory.path)' && printf changed > '\(movedAttachmentDirectory.appendingPathComponent("attached.txt").path)'") != 0)
        #expect(fm.fileExists(atPath: protectedFile.path))

        _ = run("input='\(protectedFile.path)'; trap 'rm -f \"$input\"' EXIT; :")
        #expect(fm.fileExists(atPath: protectedFile.path))

        let protectedChild = protectedDirectory.appendingPathComponent("new.txt")
        #expect(run("touch '\(protectedChild.path)'") != 0)
        #expect(!fm.fileExists(atPath: protectedChild.path))
    }

    private func runConfined(
        profile: String,
        writableRoots: [String],
        protectedWriteDenyRoots: [String],
        protectedWriteAncestorDenyRoots: [String],
        script: String
    ) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ExecutionSandbox.sandboxExecPath)
        process.arguments = ExecutionSandbox.makeArguments(
            profile: profile,
            writableRoots: writableRoots,
            protectedWriteDenyRoots: protectedWriteDenyRoots,
            protectedWriteAncestorDenyRoots: protectedWriteAncestorDenyRoots,
            executablePath: "/bin/sh",
            arguments: ["-c", script]
        )
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Issue.record("Failed to launch sandbox-exec: \(error)")
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
