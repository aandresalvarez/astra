import Foundation
import Testing
@testable import ASTRA

@Suite("Architecture Fitness")
struct ArchitectureFitnessTests {
    @Test("Services root contains only known subsystem folders")
    func servicesRootContainsOnlyKnownSubsystemFolders() throws {
        let serviceRoot = try repositoryRoot().appendingPathComponent("Astra/Services")
        let entries = try FileManager.default.contentsOfDirectory(
            at: serviceRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let directSwiftFiles = entries
            .filter { $0.pathExtension == "swift" }
            .map(\.lastPathComponent)
            .sorted()
        #expect(directSwiftFiles.isEmpty, "Move service files into an intentional subsystem folder: \(directSwiftFiles)")

        let folders = try entries
            .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
            .map(\.lastPathComponent)
            .sorted()

        #expect(folders == [
            "Browser",
            "Capabilities",
            "Diagnostics",
            "Git",
            "Persistence",
            "Runtime",
            "Settings",
            "Tasks",
            "Validation"
        ])
    }

    @Test("Prompt section provider identifiers are unique and used by known prompt modes")
    @MainActor
    func promptSectionProviderIdentifiersAreUniqueAndUsedByKnownModes() {
        let allIDs = PromptContextSectionProviderID.allCases
        let rawValues = allIDs.map(\.rawValue)

        #expect(Set(allIDs).count == allIDs.count)
        #expect(Set(rawValues).count == rawValues.count)
        #expect(rawValues.allSatisfy { $0.range(of: #"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil })

        for mode in [PromptAssemblyMode.initialRun, .followUp] {
            let providers = AgentPromptBuilder.promptSectionProviderIDs(for: mode)
            #expect(!providers.isEmpty)
            #expect(Set(providers).count == providers.count)
            #expect(providers.allSatisfy { allIDs.contains($0) })
        }
    }

    @Test("Typed task event constants are categorized explicitly")
    func typedTaskEventConstantsAreCategorizedExplicitly() throws {
        let expectedCategories: [String: TaskEventCategory] = [
            "activity.compacted": .lifecycle,
            "astra.artifact_preflight": .system,
            "budget.exceeded": .system,
            "budget.warning": .system,
            "corrective.step.approved": .lifecycle,
            "corrective.step.created": .lifecycle,
            "corrective.step.dismissed": .lifecycle,
            "corrective.task.created": .lifecycle,
            "deliverable.verification.failed": .lifecycle,
            "deliverable.verification.passed": .lifecycle,
            "deliverable.verification.review_needed": .lifecycle,
            "error": .system,
            "handoff.created": .lifecycle,
            "handoff.missing": .lifecycle,
            "handoff.updated": .lifecycle,
            "mission.action.approved": .lifecycle,
            "mission.action.correction_created": .lifecycle,
            "mission.action.dismissed": .lifecycle,
            "mission.action.retry_requested": .lifecycle,
            "mission.audit_bundle.created": .lifecycle,
            "mission.checkpoint.created": .lifecycle,
            "mission.milestone.completed": .lifecycle,
            "mission.milestone.created": .lifecycle,
            "permission.approval.requested": .system,
            "permission.denied": .tool,
            "permission.grant.task": .system,
            "plan.approved": .lifecycle,
            "plan.assistant.message": .conversation,
            "plan.cancelled": .lifecycle,
            "plan.created": .lifecycle,
            "plan.execution.completed": .lifecycle,
            "plan.execution.failed": .lifecycle,
            "plan.execution.started": .lifecycle,
            "plan.step.blocked": .tool,
            "plan.step.completed": .tool,
            "plan.step.skipped": .tool,
            "plan.step.started": .tool,
            "plan.updated": .lifecycle,
            "plan.user.message": .conversation,
            "recap.result": .system,
            "resource.lock.acquired": .lifecycle,
            "resource.lock.released": .lifecycle,
            "resource.lock.requested": .lifecycle,
            "resource.lock.waiting": .lifecycle,
            "role.profile.changed": .lifecycle,
            "role.profile.selected": .lifecycle,
            "schedule.result": .system,
            "skill.active": .system,
            "system.info": .system,
            "task.cancelled": .lifecycle,
            "task.chained": .system,
            "task.checkpoint": .lifecycle,
            "task.completed": .lifecycle,
            "task.dismissed": .lifecycle,
            "task.interrupted": .lifecycle,
            "task.resumed": .lifecycle,
            "task.retried": .lifecycle,
            "task.approved": .lifecycle,
            "task.started": .lifecycle,
            "task.stats": .system,
            "team.agent.completed": .team,
            "team.agent.started": .team,
            "team.created": .team,
            "team.deleted": .team,
            "team.message": .team,
            "tool.result": .tool,
            "tool.use": .tool,
            "user.message": .conversation,
            "agent.response": .conversation,
            "agent.thinking": .conversation,
            "validation.assertion.defined": .tool,
            "validation.assertion.failed": .tool,
            "validation.assertion.passed": .tool,
            "validation.assertion.reviewed": .tool,
            "validation.assertion.skipped": .tool,
            "validation.assertion.started": .tool,
            "validation.behavior.evidence.attached": .lifecycle,
            "validation.behavior.failed": .lifecycle,
            "validation.behavior.passed": .lifecycle,
            "validation.behavior.started": .lifecycle,
            "validation.contract.created": .lifecycle,
            "validation.contract.failed": .lifecycle,
            "validation.contract.override": .lifecycle,
            "validation.contract.passed": .lifecycle,
            "validation.contract.updated": .lifecycle,
            "validation.evidence": .system,
            "verifier.completed": .lifecycle,
            "verifier.failed": .lifecycle,
            "verifier.started": .lifecycle
        ]

        let declaredConstants = try declaredTaskEventTypeConstants()
        #expect(declaredConstants == Set(expectedCategories.keys), "Update this fitness test when adding a typed task event.")

        for (rawValue, category) in expectedCategories {
            #expect(TaskEventTypes.category(forRawValue: rawValue) == category)
            #expect(TaskEvent.categoryFor(type: rawValue) == category.rawValue)
        }
    }

    @Test("Raw stop reason assignments stay inside runtime and persistence boundaries")
    func rawStopReasonAssignmentsStayInsideBoundaries() throws {
        let root = try repositoryRoot()
        let allowedFiles: Set<String> = [
            "Astra/Services/Persistence/SessionScanner.swift",
            "Astra/Services/Runtime/AgentProcessSupport.swift",
            "Astra/Services/Runtime/AgentRuntimeBudgetPolicy.swift",
            "Astra/Services/Runtime/AgentRuntimeProcessRunner.swift",
            "Astra/Services/Runtime/AgentRuntimeWorker.swift",
            "Astra/Services/Validation/TaskCompletionPolicy.swift"
        ]

        let matches = try swiftFiles(under: root.appendingPathComponent("Astra"))
            .flatMap { file -> [String] in
                let relativePath = relativePath(for: file, root: root)
                let text = try String(contentsOf: file, encoding: .utf8)
                return text
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .enumerated()
                    .compactMap { index, line in
                        let value = String(line)
                        guard value.range(
                            of: #"(?:run|decision|_runtimeStopReason)\.?(?:stopReason)?\s*=\s*"[a-z0-9_]+""#,
                            options: .regularExpression
                        ) != nil else {
                            return nil
                        }
                        return allowedFiles.contains(relativePath) ? nil : "\(relativePath):\(index + 1): \(value.trimmingCharacters(in: .whitespaces))"
                    }
            }

        #expect(matches.isEmpty, "New raw stop reason assignments should stay behind runtime/completion/persistence boundaries: \(matches)")
    }

    @Test("Git status parsing lives behind its SwiftPM contract target")
    func gitStatusParsingLivesBehindContractTarget() throws {
        let root = try repositoryRoot()
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)

        #expect(package.contains(#"name: "ASTRAGitContracts""#))
        #expect(package.contains(#""ASTRAGitContracts","#))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("ASTRAGitContracts/GitStatusContracts.swift").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Astra/Services/Git/GitStatusParser.swift").path
        ))
    }

    @Test("Plugin catalog view delegates capability side effects to action service")
    func pluginCatalogViewDelegatesCapabilitySideEffects() throws {
        let root = try repositoryRoot()
        let view = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/PluginCatalogView.swift"),
            encoding: .utf8
        )

        #expect(!view.contains("CapabilityInstaller("))
        #expect(!view.contains("CapabilityUninstaller("))
        #expect(!view.contains("CapabilityPackageCreationService("))
        #expect(view.contains("CapabilityCatalogActionService("))
    }

    private func declaredTaskEventTypeConstants() throws -> Set<String> {
        let file = try repositoryRoot().appendingPathComponent("Astra/Models/TaskEventTypes.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"static let \w+: TaskEventType = "([^"]+)""#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        return Set(regex.matches(in: text, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[valueRange])
        })
    }

    private func repositoryRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while true {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Astra").path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                throw ArchitectureFitnessError.repositoryRootNotFound
            }
            candidate = parent
        }
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

    private func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }
}

private enum ArchitectureFitnessError: Error {
    case repositoryRootNotFound
}
