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
        #expect(Set(contract.paths) == Set([input.path, approvedRead.path, credentialRead.path].compactMap(ExecutionSandbox.canonicalize)))
        #expect(contract.resources.flatMap(\.sources).contains(.sandboxApproval))
        #expect(contract.resources.flatMap(\.sources).contains(.gitCredential))

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
