import Foundation
import Testing

/// Guards `WorkspaceCapabilityActivation` as the single owner of a workspace's
/// capability enablement state (Plugins 2.0 phase 0,
/// `docs/specs/2026-10-15-plugins-2-capability-redesign.md`).
///
/// Seven stored arrays on `Workspace` record what a workspace has turned on.
/// They were written from more than twenty places, views included, with no
/// agreement on rollback (one snapshot skipped packs) or on what an import may
/// trust. Writes now go through the owner, and this scan fails on a direct
/// write anywhere else. Reads are frozen per file: a new reader, or more reads
/// in an existing one, fails here, so phase 1 can move them behind the owner
/// without the list growing in the meantime.
///
/// This target has no package dependencies, so it is a source scan; the
/// owner's behaviour lives in `Tests/WorkspaceCapabilityActivationTests.swift`.
@Suite("Capability activation owner fitness")
struct CapabilityActivationOwnerFitnessTests {
    static let fields = [
        "enabledGlobalSkillIDs", "enabledGlobalConnectorIDs", "enabledGlobalToolIDs",
        "enabledCapabilityIDs", "enabledPackIDs", "installedPluginIDs", "installedPluginVersions"
    ]

    /// Files that may touch the stored arrays directly: the model, the owner,
    /// and the frozen schema snapshots that declare the same names.
    private func isExempt(_ relative: String) -> Bool {
        relative == "Astra/Models/Workspace.swift"
            || relative == "Astra/Models/WorkspaceCapabilityActivation.swift"
            || relative == "Astra/Models/SchemaVersions.swift"
            || (relative.hasPrefix("Astra/Models/ASTRASchemaV") && relative.hasSuffix(".swift"))
    }

    /// Writers not yet routed through the owner. Empty since phase 0; keep it
    /// that way.
    private let pendingWriters: Set<String> = []

    /// Per-file count of reads of the stored arrays. Lower an entry when a
    /// reader moves behind the owner; never raise one.
    private let readRegistry: [String: Int] = [
        "Astra/Services/Browser/ShelfQuerySession.swift": 4,
        "Astra/Services/Capabilities/CapabilityActivationDisabler.swift": 1,
        "Astra/Services/Capabilities/CapabilityAudit.swift": 5,
        "Astra/Services/Capabilities/CapabilityCatalogPolicy.swift": 2,
        "Astra/Services/Capabilities/CapabilityInstaller.swift": 3,
        "Astra/Services/Capabilities/CapabilityPackageState.swift": 4,
        "Astra/Services/Capabilities/CapabilityRuntimeIntegrityService.swift": 1,
        "Astra/Services/Capabilities/CapabilityRuntimeResourceMatcher.swift": 2,
        "Astra/Services/Capabilities/CapabilitySetupCopier.swift": 3,
        "Astra/Services/Capabilities/CapabilityUninstaller.swift": 7,
        "Astra/Services/Capabilities/MCPRuntimeProjection.swift": 1,
        // The V19 -> V20 migration reads the legacy shared-row lists it prunes.
        "Astra/Services/Capabilities/PluginActivationMigration.swift": 3,
        "Astra/Services/Capabilities/PluginCatalogPresentation.swift": 1,
        "Astra/Services/Capabilities/TaskCapabilityResolver.swift": 7,
        "Astra/Services/Capabilities/WorkspaceCapabilities.swift": 4,
        "Astra/Services/Packs/AstraPackProfileResolver.swift": 1,
        "Astra/Services/Packs/PackWorkspacePolicyProvider.swift": 1,
        "Astra/Services/Persistence/WorkspaceConfigManager+CapabilityImportTrust.swift": 5,
        "Astra/Services/Persistence/WorkspaceConfigManager.swift": 11,
        "Astra/Services/Runtime/AgentRuntimeCapabilityLaunchAudit.swift": 5,
        "Astra/Services/Runtime/AgentRuntimeLaunchPreflight.swift": 1,
        "Astra/Services/WorkspaceApps/WorkspaceAppTemplatePackCatalog.swift": 1,
        "Astra/Services/WorkspacePackage/WorkspacePackageExporter.swift": 1,
        "Astra/Services/WorkspacePackage/WorkspacePackageImportCoordinator.swift": 2,
        "Astra/Services/WorkspacePackage/WorkspaceShareProjection.swift": 2,
        "Astra/Views/ComposerCapabilitySnapshot.swift": 7,
        "Astra/Views/ConfigureView.swift": 11,
        "Astra/Views/ConnectorsManagerView.swift": 1,
        "Astra/Views/ContentView.swift": 7,
        "Astra/Views/ContentViewBrowserSessionPolicyCache.swift": 4,
        "Astra/Views/PluginCatalogView.swift": 2,
        "Astra/Views/ScheduleEditorView.swift": 1,
        "Astra/Views/ToolsManagerView.swift": 1,
        "Astra/Views/WorkspaceAppStudioChatView.swift": 1,
        "Astra/Views/WorkspaceHomeView.swift": 1,
        "Astra/Views/WorkspacePackSettingsSection.swift": 5,
        "Astra/Views/WorkspaceRightRailCapabilitySnapshotCache.swift": 15,
        "Astra/Views/WorkspaceRightRailView.swift": 2
    ]

    @Test("Capability enablement is written only through WorkspaceCapabilityActivation")
    func enablementIsWrittenOnlyThroughTheOwner() throws {
        let root = repositoryRoot()
        var violations: [String] = []
        var cleanedUp: [String] = []
        for (relative, source) in try appSources(root: root) where !isExempt(relative) {
            let writes = writeLines(in: source)
            if pendingWriters.contains(relative) {
                if writes.isEmpty { cleanedUp.append(relative) }
                continue
            }
            violations += writes.map { "\(relative):\($0.number): \($0.text)" }
        }
        #expect(
            violations.isEmpty,
            """
            Write capability enablement through `WorkspaceCapabilityActivation.mutate` \
            (or `apply`/`restore`), never the Workspace arrays directly: \(violations.sorted())
            """
        )
        #expect(
            cleanedUp.isEmpty,
            "These files no longer write enablement directly; remove them from `pendingWriters`: \(cleanedUp.sorted())"
        )
    }

    @Test("Reads of the enablement arrays stay frozen per file")
    func readsStayFrozenPerFile() throws {
        let root = repositoryRoot()
        var actual: [String: Int] = [:]
        for (relative, source) in try appSources(root: root) where !isExempt(relative) {
            let count = readCount(in: source)
            if count > 0 { actual[relative] = count }
        }
        let grew = actual.filter { (readRegistry[$0.key] ?? 0) < $0.value }
        let shrank = readRegistry.filter { (actual[$0.key] ?? 0) < $0.value }
        #expect(
            grew.isEmpty,
            """
            New or more reads of the Workspace enablement arrays. Read through \
            `WorkspaceCapabilityActivation.state(of:)` instead: \
            \(grew.sorted { $0.key < $1.key }.map { "\"\($0.key)\": \($0.value)" })
            """
        )
        #expect(
            shrank.isEmpty,
            """
            Fewer reads than registered; lower these entries in `readRegistry`: \
            \(shrank.sorted { $0.key < $1.key }.map { "\"\($0.key)\": \(actual[$0.key] ?? 0)" })
            """
        )
    }

    /// `importWorkspace` defaults to restoring a config as recorded, which is
    /// right for the workspace's own mirror and wrong for a file the user
    /// picked. Production callers must say which one they mean.
    @Test("Production config imports state their capability trust")
    func productionConfigImportsStateTheirCapabilityTrust() throws {
        let root = repositoryRoot()
        var missing: [String] = []
        for (relative, source) in try appSources(root: root) {
            missing += importCallsMissingTrust(in: source).map { "\(relative):\($0)" }
        }
        #expect(
            missing.isEmpty,
            """
            Pass `capabilityTrust:` explicitly: `.validate(.live())` for a file the user \
            chose, `.preserveRecordedState` for the workspace's own mirror: \(missing.sorted())
            """
        )
        #expect(importCallsMissingTrust(in: "WorkspaceConfigManager.importWorkspace(from: config, modelContext: ctx)") == [1])
        #expect(importCallsMissingTrust(in: """
            WorkspaceConfigManager.importWorkspaceResult(
                from: config, modelContext: ctx,
                capabilityTrust: .validate(.live())
            )
            """).isEmpty)
    }

    /// Line numbers of `WorkspaceConfigManager.importWorkspace(Result)(` calls
    /// whose balanced argument list has no `capabilityTrust:`.
    private func importCallsMissingTrust(in source: String) -> [Int] {
        let pattern = try! NSRegularExpression(pattern: #"WorkspaceConfigManager\.importWorkspace(?:Result)?\("#)
        let text = source as NSString
        return pattern.matches(in: source, range: NSRange(location: 0, length: text.length)).compactMap { match in
            var depth = 0
            var end = match.range.location + match.range.length - 1
            while end < text.length {
                let character = text.character(at: end)
                if character == 40 { depth += 1 }
                if character == 41 { depth -= 1; if depth == 0 { break } }
                end += 1
            }
            let call = text.substring(with: NSRange(location: match.range.location, length: min(end, text.length - 1) - match.range.location + 1))
            guard !call.contains("capabilityTrust:") else { return nil }
            return text.substring(to: match.range.location).components(separatedBy: "\n").count
        }
    }

    /// The scan is text-based, so it is only worth what it catches. Each shape
    /// below is a real pre-owner write; the clean ones are reads, comparisons,
    /// DTO initialisers and the owner's own value type.
    @Test("The scan recognises every shape it was written to catch")
    func theScanRecognisesEveryShapeItWasWrittenToCatch() {
        let writes = [
            "        workspace.enabledPackIDs = nextPackIDs",
            "        ws.enabledGlobalSkillIDs.append(idString)",
            "            workspace.enabledGlobalSkillIDs.remove(at: idx)",
            "        workspace.enabledGlobalToolIDs.removeAll { $0 == tool.id.uuidString }",
            "            appendUnique(connector.id.uuidString, to: &workspace.enabledGlobalConnectorIDs)",
            "        workspace.enabledCapabilityIDs = workspace.enabledCapabilityIDs.filter { id in",
            "            workspace.installedPluginVersions[idx] = version",
            "        workspace.enabledPackIDs += [\"pack\"]",
            "        Toggle(isOn: $workspace.enabledPackIDs)"
        ]
        for line in writes {
            #expect(writeLines(in: line).count == 1, "Missed a write: \(line)")
        }

        let clean = [
            "            self.enabledPackIDs = enabledPackIDs",
            "        if workspace.enabledPackIDs != nextPackIDs {",
            "        .onChange(of: workspace.enabledPackIDs) {",
            "        let ids = Set(workspace.enabledCapabilityIDs)",
            "                ? workspace.installedPluginVersions[index]",
            "        // workspace.enabledPackIDs = nextPackIDs",
            "        WorkspaceCapabilityActivation.mutate(workspace) { $0.packIDs = nextPackIDs }",
            "            $0.globalSkillIDs.removeAll { $0 == id }",
            "        let packs = workspaces.flatMap { $0.enabledPackIDs }"
        ]
        for line in clean {
            #expect(writeLines(in: line).isEmpty, "Flagged a non-write: \(line)")
        }
        #expect(readCount(in: "        .onChange(of: workspace.enabledPackIDs) {") == 1)
        #expect(readCount(in: "        workspace.enabledPackIDs = nextPackIDs") == 0)
        #expect(readCount(in: "            self.enabledPackIDs = enabledPackIDs") == 0)
    }

    // MARK: - Scanning

    private struct Line {
        let number: Int
        let text: String
    }

    private static let fieldAlternation = fields.joined(separator: "|")

    /// Compiled once: compiling per line made a full scan take minutes.
    private static let writePatterns: [NSRegularExpression] = [
        #"(?<!self)\.(\#(fieldAlternation))\s*(?:=(?!=)|\+=|-=)"#,
        #"(?<!self)\.(\#(fieldAlternation))\s*\.\s*(?:append|insert|remove\w*|sort|reverse|swapAt)\b"#,
        #"(?<!self)\.(\#(fieldAlternation))\s*\[[^\]]*\]\s*=(?!=)"#,
        #"&\s*[\w.]*\.(\#(fieldAlternation))\b"#,
        #"\$[A-Za-z_][\w.]*\.(\#(fieldAlternation))\b"#
    ].map { try! NSRegularExpression(pattern: $0) }

    private static let readPattern = try! NSRegularExpression(
        pattern: #"(?<!self)\.(\#(fieldAlternation))\b|\.installedVersion\(of:|\.installedPluginIDSet\b"#
    )

    /// Non-comment lines that name one of the arrays or their read helpers;
    /// every other line is skipped before any regex runs.
    private func candidateLines(in source: String) -> [Line] {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, raw in
                let text = String(raw)
                guard Self.fields.contains(where: { text.contains($0) })
                    || text.contains(".installedVersion(of:")
                    || text.contains(".installedPluginIDSet") else { return nil }
                if text.trimmingCharacters(in: .whitespaces).hasPrefix("//") { return nil }
                return Line(number: index + 1, text: text)
            }
    }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Int {
        pattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private func isWrite(_ text: String) -> Bool {
        Self.writePatterns.contains { Self.matches($0, text) > 0 }
    }

    private func writeLines(in source: String) -> [Line] {
        candidateLines(in: source).filter { isWrite($0.text) }
    }

    private func readCount(in source: String) -> Int {
        candidateLines(in: source)
            .filter { !isWrite($0.text) }
            .reduce(0) { $0 + Self.matches(Self.readPattern, $1.text) }
    }

    private func appSources(root: URL) throws -> [(String, String)] {
        try swiftFiles(under: root.appendingPathComponent("Astra")).map { file in
            (
                file.path.replacingOccurrences(of: root.path + "/", with: ""),
                try String(contentsOf: file, encoding: .utf8)
            )
        }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        return try enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true ? url : nil
        }
    }
}
