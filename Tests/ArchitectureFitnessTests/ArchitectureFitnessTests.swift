import Foundation
import Testing

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
            "ExternalOperations",
            "Feedback",
            "Git",
            "GoogleWorkspace",
            "Packs",
            "Persistence",
            "Runtime",
            "Settings",
            "Shelves",
            "Startup",
            "Tasks",
            "Validation",
            "WorkspaceApps",
            "WorkspacePackage"
        ])
    }

    @Test("Launch compatibility does not depend on descriptor MCP boolean")
    func launchCompatibilityDoesNotDependOnDescriptorMCPBoolean() throws {
        let root = try repositoryRoot()
        let guardedFiles = [
            "Astra/Services/Runtime/HostControlPlaneMCPProjection.swift",
            "Astra/Services/Runtime/ExecutionEnvironment.swift",
            "Astra/Services/Runtime/AgentRuntimeLaunchPreflight.swift",
            "Astra/Services/Runtime/AgentRuntimeLaunchRuntimeResolver.swift",
            "Astra/Services/Runtime/TaskRuntimeCompatibilityService.swift"
        ]

        for relativePath in guardedFiles {
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            #expect(!source.contains("descriptor(for: runtime).supportsMCPServers"))
            #expect(!source.contains("descriptor(for: selectedRuntime).supportsMCPServers"))
        }
    }

    @Test("Pack services stay in the Packs service folder")
    func packServicesStayInPacksServiceFolder() throws {
        let root = try repositoryRoot()
        let serviceRoot = root.appendingPathComponent("Astra/Services")
        // Adapters that legitimately consume the pack catalog without owning it:
        // the WorkspaceApps template-pack bridge, and the portable-workspace
        // import flow, which must reconcile a share's referenced pack IDs against
        // the recipient's real catalog (surface missing packs, drop unresolved
        // ones from the enabled set) rather than trusting arbitrary IDs.
        let allowedPackAdapters: Set<String> = [
            "Astra/Services/WorkspaceApps/WorkspaceAppTemplatePackCatalog.swift",
            "Astra/Services/WorkspacePackage/WorkspacePackageImportCoordinator.swift",
            "Astra/Services/WorkspacePackage/WorkspacePackageImportPlan.swift"
        ]
        let packServiceFilesOutsidePacks = try swiftFiles(under: serviceRoot)
            .compactMap { file -> String? in
                let path = relativePath(for: file, root: root)
                guard path.contains("/Packs/") == false else { return nil }
                guard allowedPackAdapters.contains(path) == false else { return nil }
                let text = try String(contentsOf: file, encoding: .utf8)
                return text.contains("AstraPack") ? path : nil
            }
            .sorted()

        #expect(
            packServiceFilesOutsidePacks.isEmpty,
            "Pack service files should live under Astra/Services/Packs: \(packServiceFilesOutsidePacks)"
        )
    }

    @Test("Pack source discovery goes through the file access broker")
    func packSourceDiscoveryGoesThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let relativePath = "Astra/Services/Packs/AstraPackSource.swift"
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        let forbiddenPatterns = [
            "fileManager.fileExists(",
            "FileManager.default.fileExists(",
            "fileManager.contentsOfDirectory(",
            "FileManager.default.contentsOfDirectory("
        ]

        let matches = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line -> String? in
                let value = String(line)
                guard forbiddenPatterns.contains(where: { pattern in value.contains(pattern) }) else { return nil }
                return "\(relativePath):\(index + 1)"
            }

        #expect(matches.isEmpty, "Pack source discovery should use HostFileAccessBroker: \(matches)")
    }

    @Test("Pack shelf schema does not expose dynamic SwiftUI implementation fields")
    func packShelfSchemaDoesNotExposeDynamicSwiftUIImplementationFields() throws {
        let root = try repositoryRoot()
        let relativePath = "ASTRACore/AstraPackManifest.swift"
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        let forbiddenStoredProperties = [
            "public var swiftUIViewType",
            "public var viewImplementation",
            "public var viewType",
            "public var modulePath",
            "public var bundlePath",
            "public var pluginPath"
        ]

        let matches = forbiddenStoredProperties.filter { text.contains($0) }

        #expect(
            matches.isEmpty,
            "Pack shelf manifests must reference trusted Core shelf IDs, not dynamic SwiftUI implementations: \(matches)"
        )
    }

    @Test("Shelf services stay independent of view-layer types")
    func shelfServicesStayIndependentOfViewLayerTypes() throws {
        let root = try repositoryRoot()
        let shelvesRoot = root.appendingPathComponent("Astra/Services/Shelves")
        let forbiddenSymbols = [
            "WorkspaceCanvasItem",
            "PanelLayoutGeometry"
        ]

        let matches = try swiftFiles(under: shelvesRoot)
            .flatMap { file -> [String] in
                let relativePath = relativePath(for: file, root: root)
                let text = try String(contentsOf: file, encoding: .utf8)
                return forbiddenSymbols
                    .filter { text.contains($0) }
                    .map { "\(relativePath): \($0)" }
            }
            .sorted()

        #expect(
            matches.isEmpty,
            "Shelf services must not depend on view-layer types; add a view-side adapter or neutral metrics instead: \(matches)"
        )
    }

    @Test("Workspace App Studio stays on the direct session architecture")
    func workspaceAppStudioStaysOnDirectSessionArchitecture() throws {
        let root = try repositoryRoot()
        let retiredFiles = [
            "Astra/Services/WorkspaceApps/WorkspaceAppStudioBuildTaskBuilder.swift",
            "Astra/Services/WorkspaceApps/WorkspaceAppStudioBuilderContractFactory.swift",
            "Astra/Services/WorkspaceApps/WorkspaceAppStudioContext.swift",
            "Astra/Services/WorkspaceApps/WorkspaceAppStudioContextBuilder.swift",
            "Astra/Services/WorkspaceApps/WorkspaceAppStudioContextRedactor.swift",
            "Astra/Services/WorkspaceApps/WorkspaceAppStudioDraftSupport.swift",
            "Astra/Services/WorkspaceApps/WorkspaceAppStudioGenerationTaskBuilder.swift",
            "Astra/Views/ChatPanelDraftPresentation.swift"
        ]

        let existingRetiredFiles = retiredFiles.filter {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
        #expect(existingRetiredFiles.isEmpty, "Retired task-draft App Studio files should stay removed: \(existingRetiredFiles)")

        let retiredSymbols = [
            "ChatPanelDraftPresentation",
            "WorkspaceAppStudioBuildConversationMessage",
            "WorkspaceAppStudioBuilderContract",
            "WorkspaceAppStudioBuilderContractFactory",
            "WorkspaceAppStudioBuildTaskBuilder",
            "WorkspaceAppStudioBuildTaskDraft",
            "WorkspaceAppStudioContext",
            "WorkspaceAppStudioContextBuilder",
            "WorkspaceAppStudioContextRedactor",
            "WorkspaceAppStudioContextRequest",
            "WorkspaceAppStudioDraftSupport",
            "WorkspaceAppStudioGenerationTaskBuilder",
            "WorkspaceAppStudioGenerationTaskDraft"
        ]

        let symbolMatches = try swiftFiles(under: root.appendingPathComponent("Astra"))
            .flatMap { file -> [String] in
                let relativePath = relativePath(for: file, root: root)
                let text = try String(contentsOf: file, encoding: .utf8)
                return retiredSymbols
                    .filter { text.contains($0) }
                    .map { "\(relativePath): \($0)" }
            }

        #expect(symbolMatches.isEmpty, "Workspace App Studio should be owned by WorkspaceAppStudioSession and generator, not task drafts: \(symbolMatches)")
    }

    @Test("Shelf browser snapshots go through the redaction boundary")
    func shelfBrowserSnapshotsGoThroughTheRedactionBoundary() throws {
        let root = try repositoryRoot()
        let source = try fileText("Astra/Services/Browser/ShelfBrowserSession.swift", root: root)

        #expect(!source.contains("result = json"), "Provider-visible browser snapshots must not bypass BrowserPageSnapshotService.")
        #expect(source.contains("let result = try BrowserPageSnapshotService.compactSnapshot("))
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

    @Test("High-risk SwiftData saves go through persistence coordinator")
    func highRiskSwiftDataSavesGoThroughPersistenceCoordinator() throws {
        let root = try repositoryRoot()
        // Blanket scan of the whole app target (not a hand-picked list of 5
        // files): every `modelContext.save(` must route through
        // WorkspacePersistenceCoordinator so the durable workspace JSON mirror
        // never silently lags SwiftData. `Services/Persistence/` is the
        // coordinator's own home. The remaining entries are pre-existing
        // raw-save debt to migrate onto the coordinator over time; a *new* raw
        // save anywhere outside this allowlist (including the app/runtime/view
        // edges that were already cleaned up) fails this test.
        let persistenceHomePrefix = "Astra/Services/Persistence/"
        let allowedRawSaveFiles: Set<String> = []

        let matches = try swiftFiles(under: root.appendingPathComponent("Astra"))
            .flatMap { file -> [String] in
                let relativePath = relativePath(for: file, root: root)
                if relativePath.hasPrefix(persistenceHomePrefix)
                    || allowedRawSaveFiles.contains(relativePath) {
                    return []
                }
                let text = try String(contentsOf: file, encoding: .utf8)
                return text
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .enumerated()
                    .compactMap { index, line -> String? in
                        let value = String(line)
                        guard value.range(
                            of: #"\bmodelContext\s*\.\s*save\s*\("#,
                            options: .regularExpression
                        ) != nil else {
                            return nil
                        }
                        return "\(relativePath):\(index + 1): \(value.trimmingCharacters(in: .whitespaces))"
                    }
            }
            .sorted()

        #expect(
            matches.isEmpty,
            "Route SwiftData saves through WorkspacePersistenceCoordinator (or, if unavoidable, add the file to the migrate-later allowlist in this test): \(matches)"
        )
    }

    @Test("Production task status writes go through TaskStateMachine")
    func productionTaskStatusWritesGoThroughTaskStateMachine() throws {
        let root = try repositoryRoot()
        let allowedFiles: Set<String> = [
            "Astra/Models/AgentTask.swift",
            "Astra/Models/SchemaVersions.swift",
            "Astra/Services/Tasks/TaskStateMachine.swift",
            // Track A2.6's `TaskForkStateInitializingSeam`: the transition
            // decision (guard + audit) lives entirely in the adjacent
            // `TaskStateTransitionSeamAdapter`;
            // only the mechanical `.status =`/`.updatedAt =` write of an
            // already-decided value crossed here. `AgentTaskForkService`
            // moved into `ASTRAModels` in A3 (it needs a live `AgentTask`,
            // which the seam boundary can't carry).
            "Astra/Models/AgentTaskForkService.swift",
            // Track A4's `TaskSessionStateApplyingSeam` (extending the same
            // pattern to `completeFromSessionRecovery`/`restoreImportedStatus`):
            // same reasoning - the decision + audit live in the adjacent
            // seam adapter; only the mechanical apply crossed into
            // `ASTRAPersistence`, which can't carry a live `AgentTask` either.
            "Astra/Services/Persistence/SessionScanner.swift",
            "Astra/Services/Persistence/WorkspaceConfigManager.swift",
            "Astra/Services/Persistence/WorkspaceConfigManager+ExternalOperations.swift"
        ]

        let matches = try swiftFiles(under: root.appendingPathComponent("Astra"))
            .flatMap { file -> [String] in
                let relativePath = relativePath(for: file, root: root)
                let text = try String(contentsOf: file, encoding: .utf8)
                return taskStatusWriteViolations(
                    in: text,
                    relativePath: relativePath,
                    taskStatusOwnerFiles: allowedFiles
                )
            }
            .sorted()

        #expect(
            matches.isEmpty,
            "Production AgentTask status writes should use TaskStateMachine intent methods: \(matches)"
        )
    }

    @Test("Task status write scanner catches unrecognized task receivers")
    func taskStatusWriteScannerCatchesUnrecognizedTaskReceivers() throws {
        let fixturePath = "Astra/Services/Runtime/AgentRuntimeWorker.swift"
        let fixture = """
        run.status = .completed
        selected.status = .running
        self.task.status = .failed
        workspace.tasks[i].status = .queued
        """

        let matches = taskStatusWriteViolations(
            in: fixture,
            relativePath: fixturePath,
            taskStatusOwnerFiles: []
        )

        #expect(matches == [
            "\(fixturePath):2: selected.status = .running",
            "\(fixturePath):3: self.task.status = .failed",
            "\(fixturePath):4: workspace.tasks[i].status = .queued"
        ])
    }

    @Test("Launch command builders require render-derived permission arguments")
    func launchCommandBuildersRequireRenderDerivedPermissionArguments() throws {
        let root = try repositoryRoot()
        let checkedFiles = [
            "Astra/Services/Runtime/AntigravityCLIRuntime.swift",
            "Astra/Services/Runtime/CodexCLIRuntime.swift",
            "Astra/Services/Runtime/CopilotCLIRuntime.swift",
            "Astra/Services/Runtime/CursorCLIRuntime.swift",
            "Astra/Services/Runtime/OpenCodeCLIRuntime.swift"
        ]

        let violations = try checkedFiles.flatMap { relativePath -> [String] in
            let text = try fileText(relativePath, root: root)
            let forbiddenPatterns = [
                "permissionArguments: [String]? = nil",
                "permissionArguments ??"
            ]
            return forbiddenPatterns.compactMap { pattern in
                text.contains(pattern) ? "\(relativePath): \(pattern)" : nil
            }
        }

        #expect(
            violations.isEmpty,
            "Launch builders must receive permission args derived from a persisted ProviderPolicyRender: \(violations)"
        )
    }

    @Test("Implicit host file scans go through the file access broker")
    func implicitHostFileScansGoThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let allowedFiles: Set<String> = [
            "Astra/Services/Runtime/ExecutionSandbox.swift"
        ]

        let matches = try swiftFiles(under: root.appendingPathComponent("Astra"))
            .flatMap { file -> [String] in
                let relativePath = relativePath(for: file, root: root)
                let text = try String(contentsOf: file, encoding: .utf8)
                return text
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .enumerated()
                    .compactMap { index, line in
                        guard line.contains("PrivacySensitivePathPolicy.shouldSkipImplicitScan") else {
                            return nil
                        }
                        return allowedFiles.contains(relativePath) ? nil : "\(relativePath):\(index + 1)"
                    }
            }

        #expect(matches.isEmpty, "Route implicit app-side scan checks through HostFileAccessBroker: \(matches)")
    }

    @Test("Prompt file content reads go through the file access broker")
    func promptFileContentReadsGoThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let checkedFiles = [
            "Astra/Services/Runtime/AgentPromptBuilder.swift",
            "Astra/Services/Runtime/PromptInputContextReader.swift",
            "Astra/Services/Runtime/PromptContextIOSnapshotLoader.swift"
        ]
        let forbiddenPatterns = [
            "String(contentsOfFile:",
            "String(contentsOf:",
            "Data(contentsOf:",
            "FileManager.default.contentsOfDirectory(",
            "FileManager.default.enumerator(",
            "fm.enumerator("
        ]

        let matches = try checkedFiles.flatMap { relativePath -> [String] in
            let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            return text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, line in
                    let value = String(line)
                    guard forbiddenPatterns.contains(where: value.contains) else { return nil }
                    return "\(relativePath):\(index + 1)"
                }
        }

        #expect(matches.isEmpty, "Prompt file reads should use HostFileAccessBroker: \(matches)")
    }

    @Test("Task context state file reads go through the file access broker")
    func taskContextStateFileReadsGoThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let checkedFiles = [
            "Astra/Services/Persistence/TaskContextStateManager.swift",
            "Astra/Services/Persistence/TaskContextStateOutputFiles.swift",
            "Astra/Services/Persistence/TaskContextStateRecovery.swift"
        ]

        let matches = try checkedFiles.flatMap { relativePath -> [String] in
            let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            return text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, line in
                    let value = String(line)
                    let forbiddenPatterns = [
                        "Data(contentsOf:",
                        "String(contentsOf:",
                        "String(contentsOfFile:",
                        "fileManager.contentsOfDirectory(",
                        "FileManager.default.contentsOfDirectory("
                    ]
                    guard forbiddenPatterns.contains(where: value.contains) else { return nil }
                    return "\(relativePath):\(index + 1)"
                }
        }

        #expect(matches.isEmpty, "Task context state reads should use HostFileAccessBroker: \(matches)")
    }

    @Test("Deliverable verification file reads go through the file access broker")
    func deliverableVerificationFileReadsGoThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let relativePath = "Astra/Services/Validation/TaskDeliverableVerificationService.swift"
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        let forbiddenPatterns = [
            "String(contentsOfFile:",
            "String(contentsOf:",
            "Data(contentsOf:"
        ]
        let matches = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line -> String? in
                let value = String(line)
                guard forbiddenPatterns.contains(where: { pattern in value.contains(pattern) }) else { return nil }
                return "\(relativePath):\(index + 1)"
            }

        #expect(matches.isEmpty, "Deliverable verification reads should use HostFileAccessBroker: \(matches)")
    }

    @Test("Deliverable verification reuses parsed required filenames")
    func deliverableVerificationReusesParsedRequiredFilenames() throws {
        let root = try repositoryRoot()
        let relativePath = "Astra/Services/Validation/TaskDeliverableVerificationService.swift"
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        let evaluateStart = try #require(text.range(of: "static func evaluate("))
        let evaluateTail = text[evaluateStart.lowerBound...]
        let evaluateEnd = try #require(evaluateTail.range(of: "\n    private static func "))
        let evaluate = String(evaluateTail[..<evaluateEnd.lowerBound])

        #expect(evaluate.contains("let requiredFilenames = TaskDeliverableExpectation.requiredOutputFilenames(task)"))
        #expect(
            !evaluate.contains("TaskDeliverableExpectation.requiresDeliverableArtifact(task)"),
            "Derive the verification requirement from requiredFilenames instead of parsing required output filenames twice."
        )
    }

    @Test("Task deliverable expectation scans go through the file access broker")
    func taskDeliverableExpectationScansGoThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let relativePath = "Astra/Services/Validation/TaskDeliverableExpectation.swift"
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        let forbiddenPatterns = [
            "FileManager.default.enumerator(",
            "fileManager.enumerator("
        ]
        let matches = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line -> String? in
                let value = String(line)
                guard forbiddenPatterns.contains(where: { pattern in value.contains(pattern) }) else { return nil }
                return "\(relativePath):\(index + 1)"
            }

        #expect(matches.isEmpty, "Task deliverable expectation scans should use HostFileAccessBroker: \(matches)")
    }

    @Test("Validation service artifact reads go through the file access broker")
    func validationServiceArtifactReadsGoThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let relativePath = "Astra/Services/Validation/ValidationService.swift"
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        let forbiddenPatterns = [
            "String(contentsOfFile:",
            "String(contentsOf:",
            "Data(contentsOf:"
        ]
        let matches = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line -> String? in
                let value = String(line)
                guard forbiddenPatterns.contains(where: { pattern in value.contains(pattern) }) else { return nil }
                return "\(relativePath):\(index + 1)"
            }

        #expect(matches.isEmpty, "Validation artifact reads should use HostFileAccessBroker: \(matches)")
    }

    @Test("Plan checkpoint directory checks go through the file access broker")
    func planCheckpointDirectoryChecksGoThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let relativePath = "Astra/Services/Validation/PlanStepCheckpointVerifier.swift"
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        let forbiddenPatterns = [
            "fileManager.contentsOfDirectory(",
            "FileManager.default.contentsOfDirectory(",
            ".enumerator("
        ]
        let matches = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line -> String? in
                let value = String(line)
                guard forbiddenPatterns.contains(where: { pattern in value.contains(pattern) }) else { return nil }
                return "\(relativePath):\(index + 1)"
            }

        #expect(matches.isEmpty, "Plan checkpoint directory checks should use HostFileAccessBroker: \(matches)")
    }

    @Test("Agent file change detector reads go through the file access broker")
    func agentFileChangeDetectorReadsGoThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let relativePath = "Astra/Services/Tasks/AgentFileChangeDetector.swift"
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        let forbiddenPatterns = [
            "Data(contentsOf:",
            "FileManager.default.enumerator("
        ]
        let matches = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line -> String? in
                let value = String(line)
                guard forbiddenPatterns.contains(where: { pattern in value.contains(pattern) }) else { return nil }
                return "\(relativePath):\(index + 1)"
            }

        #expect(matches.isEmpty, "Agent file-change reads should use HostFileAccessBroker: \(matches)")
    }

    @Test("Task generated file scans go through the file access broker")
    func taskGeneratedFileScansGoThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let relativePath = "Astra/Services/Tasks/TaskGeneratedFiles.swift"
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        let forbiddenPatterns = [
            "fileManager.enumerator(",
            "FileManager.default.enumerator("
        ]
        let matches = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line -> String? in
                let value = String(line)
                guard forbiddenPatterns.contains(where: { pattern in value.contains(pattern) }) else { return nil }
                return "\(relativePath):\(index + 1)"
            }

        #expect(matches.isEmpty, "Generated task-file scans should use HostFileAccessBroker: \(matches)")
    }

    @Test("Task fork manifest reads go through the file access broker")
    func taskForkManifestReadsGoThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let relativePath = "Astra/Services/Tasks/TaskForkManifestService.swift"
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        let forbiddenPatterns = [
            "contents(atPath:",
            "fileManager.contentsOfDirectory(",
            "FileManager.default.contentsOfDirectory(",
            "String(contentsOfFile:",
            "Data(contentsOf:"
        ]
        let matches = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line -> String? in
                let value = String(line)
                guard forbiddenPatterns.contains(where: { pattern in value.contains(pattern) }) else { return nil }
                return "\(relativePath):\(index + 1)"
            }

        #expect(matches.isEmpty, "Task fork manifest content reads should use HostFileAccessBroker: \(matches)")
    }

    @Test("Session history reads go through the file access broker")
    func sessionHistoryReadsGoThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let relativePath = "Astra/Services/Persistence/SessionHistoryManager.swift"
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        let forbiddenPatterns = [
            "String(contentsOfFile:",
            "String(contentsOf:",
            "Data(contentsOf:"
        ]
        let matches = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line -> String? in
                let value = String(line)
                guard forbiddenPatterns.contains(where: { pattern in value.contains(pattern) }) else { return nil }
                return "\(relativePath):\(index + 1)"
            }

        #expect(matches.isEmpty, "Session history content reads should use HostFileAccessBroker: \(matches)")
    }

    @Test("SSH connection file reads go through the file access broker")
    func sshConnectionFileReadsGoThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let relativePath = "Astra/Services/Persistence/SSHConnectionManager.swift"
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        let forbiddenPatterns = [
            "contents(atPath:",
            "String(contentsOfFile:",
            "String(contentsOf:",
            "Data(contentsOf:"
        ]
        let matches = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line -> String? in
                let value = String(line)
                guard forbiddenPatterns.contains(where: { pattern in value.contains(pattern) }) else { return nil }
                return "\(relativePath):\(index + 1)"
            }

        #expect(matches.isEmpty, "SSH connection/config reads should use HostFileAccessBroker: \(matches)")
    }

    @Test("Workspace file layout scans go through the file access broker")
    func workspaceFileLayoutScansGoThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let relativePath = "Astra/Services/Persistence/WorkspaceFileLayout.swift"
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        let forbiddenPatterns = [
            "FileManager.default.contentsOfDirectory(",
            "fileManager.contentsOfDirectory("
        ]
        let matches = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line -> String? in
                let value = String(line)
                guard forbiddenPatterns.contains(where: { pattern in value.contains(pattern) }) else { return nil }
                return "\(relativePath):\(index + 1)"
            }

        #expect(matches.isEmpty, "Workspace layout scans should use HostFileAccessBroker: \(matches)")
    }

    @Test("Claude session scanner reads go through the file access broker")
    func claudeSessionScannerReadsGoThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let relativePath = "Astra/Services/Persistence/SessionScanner.swift"
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        let forbiddenPatterns = [
            "contents(atPath:",
            "fileManager.contentsOfDirectory(",
            "FileManager.default.contentsOfDirectory(",
            "fm.contentsOfDirectory(",
            "String(contentsOfFile:",
            "String(contentsOf:",
            "Data(contentsOf:"
        ]
        let matches = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line -> String? in
                let value = String(line)
                guard forbiddenPatterns.contains(where: { pattern in value.contains(pattern) }) else { return nil }
                return "\(relativePath):\(index + 1)"
            }

        #expect(matches.isEmpty, "Claude session scanner reads should use HostFileAccessBroker: \(matches)")
    }

    @Test("Shelf file reads go through the file access broker")
    func shelfFileReadsGoThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let checkedFiles = [
            "Astra/Services/Browser/ShelfQuerySession.swift",
            "Astra/Services/Browser/ShelfMarkdownSession.swift"
        ]
        let forbiddenPatterns = [
            "String(contentsOf:",
            "String(contentsOfFile:",
            "Data(contentsOf:"
        ]

        let matches = try checkedFiles.flatMap { relativePath -> [String] in
            let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            return text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, line -> String? in
                    let value = String(line)
                    guard forbiddenPatterns.contains(where: { pattern in value.contains(pattern) }) else { return nil }
                    return "\(relativePath):\(index + 1)"
                }
        }

        #expect(matches.isEmpty, "Shelf file reads should use HostFileAccessBroker: \(matches)")
    }

    @Test("Runtime shim reads go through the file access broker")
    func runtimeShimReadsGoThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let relativePath = "Astra/Services/Runtime/AgentRuntimeProcessRunner.swift"
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        let forbiddenPatterns = [
            "String(contentsOfFile:",
            "String(contentsOf:",
            "Data(contentsOf:"
        ]
        let matches = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line -> String? in
                let value = String(line)
                guard forbiddenPatterns.contains(where: { pattern in value.contains(pattern) }) else { return nil }
                return "\(relativePath):\(index + 1)"
            }

        #expect(matches.isEmpty, "Runtime shim reads should use HostFileAccessBroker: \(matches)")
    }

    @Test("Runtime provider config reads go through the file access broker")
    func runtimeProviderConfigReadsGoThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let checkedFiles = [
            "Astra/Services/Runtime/AntigravityCLIRuntime.swift",
            "Astra/Services/Runtime/CopilotModelAvailabilityService.swift",
            "Astra/Services/Runtime/CopilotSessionMetricsReader.swift"
        ]
        let forbiddenPatterns = [
            "Data(contentsOf:",
            "String(contentsOf:",
            "String(contentsOfFile:",
            "fileManager.contentsOfDirectory(",
            "FileManager.default.contentsOfDirectory("
        ]

        let matches = try checkedFiles.flatMap { relativePath -> [String] in
            let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            return text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, line -> String? in
                    let value = String(line)
                    guard forbiddenPatterns.contains(where: { pattern in value.contains(pattern) }) else { return nil }
                    return "\(relativePath):\(index + 1)"
                }
        }

        #expect(matches.isEmpty, "Runtime provider config/log reads should use HostFileAccessBroker: \(matches)")
    }

    @Test("Capability storage reads go through the file access broker")
    func capabilityStorageReadsGoThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let checkedFiles = [
            "Astra/Services/Capabilities/ApprovedCapabilityBundle.swift",
            "Astra/Services/Capabilities/CapabilityApprovalStore.swift",
            "Astra/Services/Capabilities/CapabilityLibrary.swift",
            "Astra/Services/Capabilities/CapabilityPackageSource.swift",
            "Astra/Services/Capabilities/CapabilityRuntimeResourceMatcher.swift",
            "Astra/Services/Capabilities/BundledToolInstaller.swift",
            "Astra/Services/Capabilities/MCPRuntimeProjection.swift",
            "Astra/Services/Capabilities/StanfordOutlookMail.swift"
        ]
        let forbiddenPatterns = [
            "Data(contentsOf:",
            "String(contentsOf:",
            "String(contentsOfFile:",
            "fileManager.contentsOfDirectory(",
            "FileManager.default.contentsOfDirectory("
        ]

        let matches = try checkedFiles.flatMap { relativePath -> [String] in
            let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            return text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, line -> String? in
                    let value = String(line)
                    guard forbiddenPatterns.contains(where: { pattern in value.contains(pattern) }) else { return nil }
                    return "\(relativePath):\(index + 1)"
                }
        }

        #expect(matches.isEmpty, "Capability storage reads should use HostFileAccessBroker: \(matches)")
    }

    @Test("Claude settings reads go through the file access broker")
    func claudeSettingsReadsGoThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let relativePath = "Astra/Services/Settings/ClaudeSettingsStore.swift"
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        let forbiddenPatterns = [
            "contents(atPath:",
            "Data(contentsOf:",
            "String(contentsOf:",
            "String(contentsOfFile:"
        ]
        let matches = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line -> String? in
                let value = String(line)
                guard forbiddenPatterns.contains(where: { pattern in value.contains(pattern) }) else { return nil }
                return "\(relativePath):\(index + 1)"
            }

        #expect(matches.isEmpty, "Claude settings reads should use HostFileAccessBroker: \(matches)")
    }

    @Test("Diagnostics reads go through the file access broker")
    func diagnosticsReadsGoThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let checkedFiles = [
            "Astra/Services/Diagnostics/CrashDiagnosticsService.swift",
            "Astra/Services/Diagnostics/LogDiagnosticsService.swift",
            "Astra/Services/Diagnostics/Logger.swift"
        ]
        let forbiddenPatterns = [
            "Data(contentsOf:",
            "String(contentsOf:",
            "String(contentsOfFile:",
            "fileManager.contentsOfDirectory(",
            "FileManager.default.contentsOfDirectory("
        ]

        let matches = try checkedFiles.flatMap { relativePath -> [String] in
            let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            return text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, line -> String? in
                    let value = String(line)
                    guard forbiddenPatterns.contains(where: { pattern in value.contains(pattern) }) else { return nil }
                    return "\(relativePath):\(index + 1)"
                }
        }

        #expect(matches.isEmpty, "Diagnostics reads should use HostFileAccessBroker: \(matches)")
    }

    @Test("Task file UI scans go through the file access broker")
    func taskFileUIScansGoThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let checkedFiles = [
            "Astra/Views/TaskDetailView.swift",
            "Astra/Views/TaskFileIndex.swift"
        ]
        let forbiddenPatterns = [
            "FileManager.default.enumerator(",
            "fileManager.enumerator(",
            "Data(contentsOf:",
            "String(contentsOf:",
            "String(contentsOfFile:"
        ]

        let matches = try checkedFiles.flatMap { relativePath -> [String] in
            let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            return text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, line -> String? in
                    let value = String(line)
                    guard forbiddenPatterns.contains(where: { pattern in value.contains(pattern) }) else { return nil }
                    return "\(relativePath):\(index + 1)"
                }
        }

        #expect(matches.isEmpty, "Task file UI scans should use HostFileAccessBroker: \(matches)")
    }

    @Test("Workspace config imports go through the file access broker")
    func workspaceConfigImportsGoThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let relativePath = "Astra/Services/Persistence/WorkspaceConfigManager.swift"
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        let matches = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line -> String? in
                guard line.contains("Data(contentsOf:") else { return nil }
                return "\(relativePath):\(index + 1)"
            }

        #expect(matches.isEmpty, "Workspace config imports should use HostFileAccessBroker: \(matches)")
    }

    @Test("Workspace import discovery scans go through the file access broker")
    func workspaceImportDiscoveryScansGoThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let relativePath = "Astra/Services/Persistence/WorkspaceImportDiscovery.swift"
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        let forbiddenPatterns = [
            "fileManager.contentsOfDirectory(",
            "FileManager.default.contentsOfDirectory(",
            ".enumerator("
        ]
        let matches = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line -> String? in
                let value = String(line)
                guard forbiddenPatterns.contains(where: { pattern in value.contains(pattern) }) else { return nil }
                return "\(relativePath):\(index + 1)"
            }

        #expect(matches.isEmpty, "Workspace import discovery scans should use HostFileAccessBroker: \(matches)")
    }

    @Test("Workspace package subsystem goes through the file access broker")
    func workspacePackageSubsystemGoesThroughFileAccessBroker() throws {
        let root = try repositoryRoot()
        let relativePaths = [
            "Astra/Services/WorkspacePackage/WorkspacePackageExporter.swift",
            "Astra/Services/WorkspacePackage/WorkspacePackageService.swift",
            "Astra/Services/WorkspacePackage/WorkspacePackageImportCoordinator.swift",
            "Astra/Services/WorkspacePackage/WorkspacePackageImportPlan.swift",
            "Astra/Services/WorkspacePackage/WorkspaceShareProjection.swift"
        ]
        // Raw FileManager-prefixed reads are forbidden; `broker.enumerator(`
        // (routed through HostFileAccessBroker) and the O_NOFOLLOW reads in
        // PortablePackageSafeFileReader are the sanctioned paths.
        let forbiddenPatterns = [
            "Data(contentsOf:",
            "FileManager.default.enumerator(",
            "fileManager.enumerator(",
            "FileManager.default.contentsOfDirectory(",
            "fileManager.contentsOfDirectory("
        ]
        var matches: [String] = []
        for relativePath in relativePaths {
            let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where forbiddenPatterns.contains(where: { String(line).contains($0) }) {
                matches.append("\(relativePath):\(index + 1)")
            }
        }

        #expect(matches.isEmpty, "Workspace package reads should use HostFileAccessBroker: \(matches)")
    }

    @Test("Workspace recovery config loads keep implicit scan intent")
    func workspaceRecoveryConfigLoadsKeepImplicitScanIntent() throws {
        let root = try repositoryRoot()
        let relativePath = "Astra/Services/Persistence/WorkspaceRecoveryService.swift"
        let lines = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        let matches = lines.enumerated().compactMap { index, line -> String? in
            guard line.contains("WorkspaceConfigManager.loadConfig") else {
                return nil
            }
            let window = lines[index..<min(lines.count, index + 6)].joined(separator: "\n")
            return window.contains("accessIntent:") ? nil : "\(relativePath):\(index + 1)"
        }

        #expect(matches.isEmpty, "Recovered config loads should preserve implicit scan intent: \(matches)")
    }

    @Test("Persistent store recovery keeps policy, persistence, and UI boundaries separate")
    func persistentStoreRecoveryKeepsLayerBoundaries() throws {
        let root = try repositoryRoot()
        let policyPath = "Astra/Services/Startup/PersistentStoreRecoveryPolicy.swift"
        let viewPath = "Astra/Services/Startup/StoreStartupBlockedView.swift"
        let persistencePath = "Astra/Services/Persistence/PersistentStoreCompatibility.swift"
        let migratorPath = "Astra/Services/Persistence/OrphanedV12StoreMigrator.swift"
        let appPath = "Astra/ASTRAApp.swift"
        let policy = try String(contentsOf: root.appendingPathComponent(policyPath), encoding: .utf8)
        let persistence = try String(contentsOf: root.appendingPathComponent(persistencePath), encoding: .utf8)
        let migrator = try String(contentsOf: root.appendingPathComponent(migratorPath), encoding: .utf8)
        let app = try String(contentsOf: root.appendingPathComponent(appPath), encoding: .utf8)

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(viewPath).path))
        #expect(!policy.contains("import SwiftUI"))
        #expect(!policy.contains("NSOpenPanel"))
        #expect(!persistence.contains("import SwiftUI"))
        #expect(!persistence.contains("import AppKit"))
        #expect(!migrator.contains("import SwiftUI"))
        #expect(!migrator.contains("import AppKit"))
        #expect(!app.contains("struct StoreStartupBlockedView"))
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
        // Catalog reload ownership is limited to initial population and the
        // centralized typed persistence-event handler. Mutation callbacks
        // must not add post-action reloads of their own.
        #expect(view.components(separatedBy: "catalog.loadApprovedCapabilities(").count - 1 == 2)
        #expect(view.contains("catalog.loadApprovedCapabilities(announceLibraryMutations: false)"))
    }

    @Test("Catalog invalidations follow durable capability mutations")
    func catalogInvalidationsFollowDurableMutations() throws {
        let root = try repositoryRoot()
        let configure = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/ConfigureView.swift"), encoding: .utf8)
        let creation = try String(
            contentsOf: root.appendingPathComponent("Astra/Services/Capabilities/CapabilityPackageCreationService.swift"),
            encoding: .utf8)
        let catalogView = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/PluginCatalogView.swift"), encoding: .utf8)

        #expect(configure.contains("CapabilityPersistence.saveResourceMutation"))
        let resourcesStart = try #require(configure.range(of: "struct ConnectorsTabContent"))
        let resourcesEnd = try #require(configure.range(of: "// MARK: - Templates Tab"))
        #expect(!configure[resourcesStart.lowerBound..<resourcesEnd.lowerBound].contains(
            "WorkspacePersistenceCoordinator.saveAndAutoExport"))
        let suppressedInstall = try #require(creation.range(of: "announceCatalogMutation: false"))
        let approvalSave = try #require(creation.range(of: "let approvalRecord = try saveApprovalRecordIfNeeded"))
        let globalPost = try #require(creation.range(of: "CapabilityCatalogPersistenceEvents.post(.global)", range: approvalSave.lowerBound..<creation.endIndex))
        #expect(suppressedInstall.lowerBound < approvalSave.lowerBound)
        #expect(approvalSave.lowerBound < globalPost.lowerBound)
        #expect(catalogView.contains("CapabilityPersistence.saveResourceMutation(workspace: workspace"))
    }

    @Test("Plugin catalog approval refresh cancels stale loads")
    func pluginCatalogApprovalRefreshCancelsStaleLoads() throws {
        let root = try repositoryRoot()
        let view = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/PluginCatalogView.swift"),
            encoding: .utf8
        )

        #expect(view.contains("@State private var approvalRecordsRefreshTask: Task<Void, Never>?"))
        #expect(view.contains("@State private var approvalRecordsRefreshGeneration = 0"))
        #expect(view.contains("approvalRecordsRefreshTask?.cancel()"))
        #expect(view.contains("approvalRecordsRefreshGeneration == refreshGeneration"))
        #expect(view.contains("cancelApprovalRecordsRefresh()"))
    }

    @Test("Admin policy contexts come only from the currentUser factory")
    func adminPolicyContextsComeOnlyFromCurrentUserFactory() throws {
        // Single-user admin semantics live in exactly one place:
        // CapabilityCatalogPolicyContext.currentUser. A scattered
        // `isAdmin: true` literal is how a future non-admin mode ships
        // half-broken.
        let root = try repositoryRoot()
        let astraRoot = root.appendingPathComponent("Astra")
        let enumerator = FileManager.default.enumerator(
            at: astraRoot,
            includingPropertiesForKeys: nil
        )
        var offenders: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard contents.contains("isAdmin: true") else { continue }
            if url.lastPathComponent != "CapabilityCatalogPolicy.swift" {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(
            offenders.isEmpty,
            "Use CapabilityCatalogPolicyContext.currentUser instead of literal isAdmin contexts: \(offenders.joined(separator: ", "))"
        )
    }

    @Test("Remote MCP gateway trust uses canonical built-in source metadata")
    func remoteMCPGatewayTrustUsesCanonicalBuiltInSourceMetadata() throws {
        let root = try repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Astra/Services/Runtime/RemoteMCPGatewayEndpointTrustPolicy.swift"),
            encoding: .utf8
        )

        #expect(policy.contains("CapabilitySourceMetadata.builtIn()"))
        #expect(!policy.contains(#"packageSourceMetadata?.id == "built-in""#))
        #expect(!policy.contains(#"packageSourceMetadata?.kind == "built-in""#))
        #expect(!policy.contains(#"packageSourceMetadata?.trustLevel == "built-in""#))
    }

    @Test("Plugin catalog import presentation lives with catalog presentation contracts")
    func pluginCatalogImportPresentationLivesWithCatalogPresentationContracts() throws {
        let root = try repositoryRoot()
        let view = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/PluginCatalogView.swift"),
            encoding: .utf8
        )
        let presentation = try String(
            contentsOf: root.appendingPathComponent("Astra/Services/Capabilities/PluginCatalogPresentation.swift"),
            encoding: .utf8
        )

        #expect(!view.contains("enum CapabilityImportPresentation"))
        #expect(presentation.contains("enum CapabilityImportPresentation"))
    }

    @Test("Plugin catalog body uses cached presentation projection")
    func pluginCatalogBodyUsesCachedPresentationProjection() throws {
        let root = try repositoryRoot()
        let view = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/PluginCatalogView.swift"),
            encoding: .utf8
        )

        #expect(view.contains("let state = cachedPresentationState"))
        #expect(!view.contains("let state = presentationState"))
        #expect(view.contains("PluginCatalogPresentationCache"))
        let presentation = try String(
            contentsOf: root.appendingPathComponent("Astra/Services/Capabilities/PluginCatalogPresentation.swift"),
            encoding: .utf8
        )
        #expect(!presentation.contains("@Observable\nfinal class PluginCatalogPresentationCache"))
        for resourceView in ["ConnectorsManagerView.swift", "SkillsManagerView.swift", "ToolsManagerView.swift"] {
            let source = try String(
                contentsOf: root.appendingPathComponent("Astra/Views/\(resourceView)"),
                encoding: .utf8
            )
            #expect(source.contains("CapabilityPersistence.saveResourceMutation"))
        }
        #expect(!view.contains("JSONEncoder().encode(catalog.packages)"))
        #expect(!view.contains("catalogResourceRevision"))
    }

    @Test("Workspace rail view keeps pure presentation contracts extracted")
    func workspaceRailViewKeepsPurePresentationContractsExtracted() throws {
        let root = try repositoryRoot()
        let railView = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/WorkspaceRightRailView.swift"),
            encoding: .utf8
        )
        let presentationFile = root.appendingPathComponent("Astra/Views/WorkspaceRightRailPresentation.swift")

        #expect(FileManager.default.fileExists(atPath: presentationFile.path))
        #expect(!railView.contains("enum WorkspaceRightRailPresentation"))
        #expect(!railView.contains("enum CapabilityRailLayout"))
        #expect(!railView.contains("enum CapabilityRailSectionPresentation"))
        #expect(!railView.contains("struct CapabilityRailPackagePresentation"))
    }

    @Test("Docked sidebar keeps its column width spec outermost")
    func dockedSidebarKeepsColumnWidthSpecOutermost() throws {
        let root = try repositoryRoot()
        let contentView = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/ContentView.swift"),
            encoding: .utf8
        )

        let bodyStart = try #require(contentView.range(of: "private var sidebarArea: some View {"))
        let searchTail = contentView[bodyStart.upperBound...]
        let bodyEnd = try #require(searchTail.range(of: "\n    private var "))
        let sidebarArea = searchTail[..<bodyEnd.lowerBound]

        let widthSpec = try #require(
            sidebarArea.range(of: ".navigationSplitViewColumnWidth("),
            "The docked sidebar column must declare min/ideal/max widths."
        )

        // Regression guard for the unconstrained-resize bug: wrappers interposed
        // between the width spec and the column root (notably `.clipped()` before
        // `.toolbar(removing:)`) make NavigationSplitView drop min/ideal/max
        // entirely — the divider then drags to any width. The spec must be the
        // outermost modifier in the chain.
        for wrapper in [".clipped()", ".toolbar(removing: .sidebarToggle)", ".transition(", ".animation("] {
            let range = try #require(
                sidebarArea.range(of: wrapper),
                "Expected \(wrapper) in sidebarArea; update this test if the chain changed."
            )
            #expect(
                range.upperBound <= widthSpec.lowerBound,
                "\(wrapper) must be applied before .navigationSplitViewColumnWidth so the width spec stays outermost."
            )
        }
    }

    @Test("Content view browser policy render path does not scan filesystem revisions")
    func contentViewBrowserPolicyRenderPathDoesNotScanFilesystemRevisions() throws {
        let root = try repositoryRoot()
        let contentView = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/ContentView.swift"),
            encoding: .utf8
        )
        let policyStart = try #require(contentView.range(of: "private var currentBrowserSessionPolicy:"))
        let policyTail = contentView[policyStart.lowerBound...]
        let policyEnd = try #require(policyTail.range(of: "private func normalizedEnabledCapabilityIDs"))
        let renderPolicy = policyTail[..<policyEnd.lowerBound]

        #expect(!renderPolicy.contains("revisionFingerprint()"))
        #expect(!renderPolicy.contains("packageDefinitionsFingerprint()"))
        #expect(!renderPolicy.contains("taskEventRevision(for:"))
        #expect(!renderPolicy.contains("events.count"))
        #expect(!renderPolicy.contains("events.filter"))
        #expect(!renderPolicy.contains("BrowserSessionPolicyContext.Snapshot"))
        #expect(!renderPolicy.contains("DockerExecutionPlanner.resolveEnvironment"))
        #expect(renderPolicy.contains("browserSessionPolicyRefreshGate.policy"))
    }

    @Test("Task switches fail browser policy closed before session binding")
    func taskSwitchInvalidatesBrowserPolicyBeforeBinding() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent("Astra/Views/ContentView.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "private func handleSelectedTaskIdentityChanged"))
        let body = source[start.lowerBound...]
        let begin = try #require(body.range(of: "browserSessionPolicyRefreshGate.begin()"))
        let bind = try #require(body.range(of: "bindTaskScopedSessions"))
        #expect(begin.lowerBound < bind.lowerBound)
    }

    @Test("Browser policy performs capability and package resolution after the detached boundary")
    func browserPolicyResolutionStaysBehindDetachedBoundary() throws {
        let root = try repositoryRoot()
        let contentView = try String(
            contentsOf: root.appendingPathComponent("Astra/Views/ContentView.swift"),
            encoding: .utf8
        )
        let start = try #require(contentView.range(of: "private func refreshBrowserSessionPolicy(source:"))
        let tail = contentView[start.lowerBound...]
        let end = try #require(tail.range(of: "private func handleBrowserPolicyTaskEventInsertion"))
        let refresh = String(tail[..<end.lowerBound])
        let detached = try #require(refresh.range(of: "Task.detached(priority: .userInitiated)"))
        let beforeDetached = refresh[..<detached.lowerBound]

        #expect(!beforeDetached.contains("TaskCapabilityResolutionSnapshot.capture"))
        #expect(!beforeDetached.contains("packageDefinitions()"))
        #expect(!beforeDetached.contains("packageDefinitionsFingerprint()"))
        #expect(!beforeDetached.contains("CapabilityCatalogPolicyContext.workspaceUser"))
        #expect(!beforeDetached.contains("PackWorkspacePolicyProvider.resolvedPolicy"))
        #expect(!beforeDetached.contains("$0.runs"))
        let begin = try #require(beforeDetached.range(of: "browserSessionPolicyRefreshGate.begin()"))
        let failClosedSync = try #require(beforeDetached.range(of: "syncBrowserPresentation()"))
        #expect(begin.upperBound <= failClosedSync.lowerBound)
        let detachedTail = refresh[detached.lowerBound...]
        #expect(detachedTail.contains("catalogPolicyInput?.resolve()"))
        #expect(detachedTail.contains("hostControlInput?.resolve(packageDefinitions: packages)"))

        let environmentSource = try String(contentsOf: root.appendingPathComponent(
            "Astra/Services/Runtime/ExecutionEnvironment.swift"
        ), encoding: .utf8)
        let resolverStart = try #require(environmentSource.range(of: "static func resolveEnvironment(for task:"))
        let resolverTail = environmentSource[resolverStart.lowerBound...]
        let historicalReturn = try #require(resolverTail.range(of: "task.status != .draft"))
        let workspaceRead = try #require(resolverTail.range(of: "task.workspace?.activeExecutionEnvironmentJSON"))
        #expect(historicalReturn.lowerBound < workspaceRead.lowerBound)
    }

    @Test("Browser policy event context stays bounded and user messages use the typed insertion boundary")
    func browserPolicyEventContextUsesBoundedTypedInsertion() throws {
        let root = try repositoryRoot()
        let cache = try String(contentsOf: root.appendingPathComponent(
            "Astra/Views/ContentViewBrowserSessionPolicyCache.swift"
        ), encoding: .utf8)
        let taskMain = try String(contentsOf: root.appendingPathComponent(
            "Astra/Views/TaskMainView.swift"
        ), encoding: .utf8)

        #expect(!cache.contains("task.events.map"))
        #expect(cache.contains("descriptor.fetchLimit = 1"))
        #expect(taskMain.contains("TaskEventInsertionService.insert(userEvent"))
    }

    @Test("Host-control admission does not traverse SwiftData relationships")
    func hostControlAdmissionUsesOnlyStoredScalars() throws {
        let root = try repositoryRoot()
        let cache = try String(contentsOf: root.appendingPathComponent(
            "Astra/Views/ContentViewBrowserSessionPolicyCache.swift"
        ), encoding: .utf8)
        let start = try #require(cache.range(of:
            "init(task: AgentTask, enabledPackageIDs: [String], contextText: String)"))
        let tail = cache[start.lowerBound...]
        let end = try #require(tail.range(of: "func resolve(packageDefinitions:"))
        let admission = tail[..<end.lowerBound]

        for forbidden in ["task.events", "task.skills", "task.workspace", "task.skillSnapshots",
                          ".connectors", ".localTools", "ModelContext", "FetchDescriptor"] {
            #expect(!admission.contains(forbidden), "Admission must not access \(forbidden)")
        }
        #expect(admission.contains("task.id"))
    }

    @Test("Large Swift files stay within owned debt budgets")
    func largeSwiftFilesStayWithinOwnedDebtBudgets() throws {
        let root = try repositoryRoot()
        let violations = try lineBudgetRegistry.compactMap { relativePath, entry -> String? in
            let count = try lineCount(for: root.appendingPathComponent(relativePath))
            return count > entry.budget ? "\(relativePath): \(count) > \(entry.budget)" : nil
        }

        #expect(
            violations.isEmpty,
            "Large owner files should shrink or move behind focused boundaries instead of growing: \(violations.sorted())"
        )
    }

    @Test("Oversized Swift files have line-budget ownership")
    func oversizedSwiftFilesHaveLineBudgetOwnership() throws {
        let root = try repositoryRoot()
        let scanRoots = ["Astra", "ASTRACore", "Tools", "Tests"]
        let oversizedFiles = try scanRoots
            .flatMap { try swiftFiles(under: root.appendingPathComponent($0)) }
            .map { relativePath(for: $0, root: root) }
            .filter { path in
                try lineCount(for: root.appendingPathComponent(path)) > lineBudgetThreshold
            }
            .sorted()

        let missing = oversizedFiles.filter { lineBudgetRegistry[$0] == nil }

        #expect(
            missing.isEmpty,
            "Every Swift file over \(lineBudgetThreshold) lines needs an explicit owner or companion budget entry: \(missing)"
        )
    }

    @Test("Line-budget companion entries reference budgeted owners")
    func lineBudgetCompanionEntriesReferenceBudgetedOwners() {
        let invalid = lineBudgetRegistry.compactMap { path, entry -> String? in
            guard case let .companion(owner) = entry.classification else { return nil }
            guard let ownerEntry = lineBudgetRegistry[owner],
                  case .owner = ownerEntry.classification else {
                return "\(path) -> \(owner)"
            }
            return nil
        }

        #expect(
            invalid.isEmpty,
            "Companion line-budget entries must point at production owner entries: \(invalid.sorted())"
        )
    }

    @Test("Line-budget registry does not carry stale entries")
    func lineBudgetRegistryDoesNotCarryStaleEntries() throws {
        let root = try repositoryRoot()
        let stale = try lineBudgetRegistry.compactMap { path, _ -> String? in
            let count = try lineCount(for: root.appendingPathComponent(path))
            return count <= lineBudgetThreshold ? "\(path): \(count)" : nil
        }

        #expect(
            stale.isEmpty,
            "Remove line-budget entries once files shrink under \(lineBudgetThreshold) lines: \(stale.sorted())"
        )
    }

    @Test("Runtime adapter docs match registered providers")
    func runtimeAdapterDocsMatchRegisteredProviders() throws {
        let root = try repositoryRoot()
        let docs = try fileText("docs/architecture/runtime-adapters.md", root: root)
        let adapterSource = try fileText("Astra/Services/Runtime/AgentRuntimeAdapter.swift", root: root)
        let runtimeTypesSource = try fileText("ASTRACore/AgentRuntimeTypes.swift", root: root)
        let registeredProviders = Set(try regexCaptures(
            #"([A-Za-z0-9]+RuntimeAdapterProvider)\(\)"#,
            in: adapterSource
        ))
        let runtimeIDs = Set(try regexCaptures(
            #"AgentRuntimeID\(staticRawValue: "([^"]+)"\)"#,
            in: runtimeTypesSource
        ))
        let documentedProviders = Set(try regexCaptures(
            #"([A-Za-z0-9]+RuntimeAdapterProvider)"#,
            in: docs
        ))

        let missingProviders = registeredProviders.subtracting(documentedProviders).sorted()
        let missingRuntimeIDs = runtimeIDs.filter { !docs.contains($0) }.sorted()

        #expect(!registeredProviders.isEmpty, "Runtime adapter provider extraction should find built-in providers.")
        #expect(!runtimeIDs.isEmpty, "Runtime ID extraction should find static runtime IDs.")
        #expect(missingProviders.isEmpty, "Runtime adapter docs are missing registered providers: \(missingProviders)")
        #expect(missingRuntimeIDs.isEmpty, "Runtime adapter docs are missing runtime IDs: \(missingRuntimeIDs)")
    }

    @Test("Runtime seam registration stays wired through the load-time test bootstrap")
    func runtimeSeamRegistrationStaysWiredThroughLoadTimeTestBootstrap() throws {
        let root = try repositoryRoot()

        // The bootstrap's three pieces reference each other only by C symbol
        // name and Package.swift wiring — nothing fails at compile time if
        // one drifts; seam-reading suites would just crash whenever Swift
        // Testing happened to schedule one of them first. Pin the wiring.
        let cSymbol = "astra_test_register_runtime_seams"

        let constructor = try fileText("Tests/AstraTestSeamBootstrap/AstraTestSeamBootstrap.c", root: root)
        #expect(constructor.contains("__attribute__((constructor))"))
        #expect(constructor.contains("\(cSymbol)();"))

        let shim = try fileText("Tests/RuntimeSeamTestBootstrap.swift", root: root)
        #expect(shim.contains("@_cdecl(\"\(cSymbol)\")"))
        #expect(shim.contains("RuntimeSeamRegistration.registerAll()"))
        #expect(shim.contains("astra_test_seam_bootstrap_force_link()"))

        let manifest = try fileText("Package.swift", root: root)
        #expect(manifest.contains(#"name: "AstraTestSeamBootstrap""#))
        #expect(manifest.contains(#"path: "Tests/AstraTestSeamBootstrap""#))
        #expect(
            manifest.components(separatedBy: "\"AstraTestSeamBootstrap\"").count - 1 >= 3,
            "ASTRATests must declare the AstraTestSeamBootstrap target, depend on it, and exclude its directory from its own sources."
        )

        // Per-suite registration is what made the old guard pattern a
        // scheduling roulette; exactly one file (the bootstrap shim) may
        // reference the registration entry point.
        let bootstrapShim = "Tests/RuntimeSeamTestBootstrap.swift"
        var offenders: [String] = []
        for file in try swiftFiles(under: root.appendingPathComponent("Tests")) {
            let relative = relativePath(for: file, root: root)
            if relative == bootstrapShim { continue }
            // This suite mentions the symbol only inside string literals.
            if relative.hasPrefix("Tests/ArchitectureFitnessTests/") { continue }
            let contents = try String(contentsOf: file, encoding: .utf8)
            if contents.contains("RuntimeSeamRegistration") {
                offenders.append(relative)
            }
        }
        #expect(
            offenders.isEmpty,
            "Runtime seams are registered once, by the load-time bootstrap in \(bootstrapShim); remove per-suite RuntimeSeamRegistration calls from: \(offenders.sorted())"
        )
    }

    @Test("Architecture docs cover Workspace Apps and execution environments")
    func architectureDocsCoverWorkspaceAppsAndExecutionEnvironments() throws {
        let root = try repositoryRoot()
        let workspaceApps = try fileText("docs/architecture/workspace-apps.md", root: root)
        let executionEnvironments = try fileText("docs/architecture/execution-environments.md", root: root)

        for expected in ["WorkspaceAppManifest", "WorkspaceAppService", "WorkspaceAppActionExecutor"] {
            #expect(workspaceApps.contains(expected), "Workspace Apps docs should cover \(expected)")
        }
        for expected in ["ExecutionEnvironment", "ExecutionEnvironmentProviderPlacement", "WorkspaceDockerViewModel"] {
            #expect(executionEnvironments.contains(expected), "Execution environment docs should cover \(expected)")
        }
    }

    @Test("Model secret persistence owns Keychain IO for model classes")
    func modelSecretPersistenceOwnsKeychainIOForModelClasses() throws {
        let root = try repositoryRoot()
        let modelFiles = [
            "Astra/Models/Connector.swift",
            "Astra/Models/Skill.swift"
        ]
        let violations = try modelFiles.compactMap { path -> String? in
            let text = try fileText(path, root: root)
            return text.contains("KeychainService.") ? path : nil
        }
        let service = try fileText("Astra/Services/Capabilities/ModelSecretPersistence.swift", root: root)

        #expect(violations.isEmpty, "SwiftData models must delegate Keychain IO to services: \(violations)")
        #expect(service.contains("KeychainService."), "ModelSecretPersistence should own the KeychainService boundary.")
    }

    @Test("Direct AppStorage usage does not grow")
    func directAppStorageUsageDoesNotGrow() throws {
        let root = try repositoryRoot()
        let count = try occurrenceCount(
            pattern: "@AppStorage",
            files: swiftFiles(under: root.appendingPathComponent("Astra")) +
                swiftFiles(under: root.appendingPathComponent("ASTRACore"))
        )

        // Ratchet bumped 125 -> 130 for the execution-sandbox settings
        // (sandboxEnforcement / sandboxReadScope / sandboxAllowNetwork /
        // sandboxLayerNativeProviders), which are user-facing toggles following
        // the existing SettingsView pattern.
        #expect(count <= 130, "Prefer settings snapshots or stores over new direct @AppStorage reads. Current count: \(count)")
    }

    @Test("Files shelf does not decode image previews from SwiftUI body")
    func filesShelfDoesNotDecodeImagePreviewsFromSwiftUIBody() throws {
        let root = try repositoryRoot()
        let shelfView = try fileText("Astra/Views/ShelfMarkdownPanelView.swift", root: root)
        let shelfSession = try fileText("Astra/Services/Browser/ShelfMarkdownSession.swift", root: root)

        #expect(!shelfView.contains("NSImage(contentsOf:"))
        #expect(shelfSession.contains("NSImage(contentsOf:"))
    }

    @Test("Files shelf image reload fast-paths unchanged previews before decoding")
    func filesShelfImageReloadFastPathsUnchangedPreviewsBeforeDecoding() throws {
        let root = try repositoryRoot()
        let shelfSession = try fileText("Astra/Services/Browser/ShelfMarkdownSession.swift", root: root)
        let loadStart = try #require(shelfSession.range(of: "func load(_ url: URL)"))
        let selectStart = try #require(shelfSession[loadStart.upperBound...].range(of: "func selectDocument"))
        let loadBody = String(shelfSession[loadStart.lowerBound..<selectStart.lowerBound])
        let reuseFastPath = try #require(loadBody.range(of: "reuseUnchangedImageDocument"))
        let fullDocumentLoad = try #require(loadBody.range(of: "Self.makeDocument(for: url)"))

        #expect(reuseFastPath.lowerBound < fullDocumentLoad.lowerBound)
    }

    @Test("Task answer text selection uses explicit safe policy")
    func taskAnswerTextSelectionUsesExplicitSafePolicy() throws {
        let root = try repositoryRoot()
        let taskMainView = try fileText("Astra/Views/TaskMainView.swift", root: root)
        let markdownTextView = try fileText("Astra/Views/MarkdownTextView.swift", root: root)
        let completedAgentMarkdownView = try extractedStruct(
            named: "CompletedAgentMarkdownView",
            from: taskMainView
        )
        let streamingAgentTextView = try extractedStruct(
            named: "StreamingAgentTextView",
            from: taskMainView
        )
        let listItemStart = try #require(markdownTextView.range(of: "case .listItem"))
        let blockquoteStart = try #require(markdownTextView[listItemStart.upperBound...].range(of: "case .blockquote"))
        let listItemCase = String(markdownTextView[listItemStart.lowerBound..<blockquoteStart.lowerBound])

        #expect(completedAgentMarkdownView.contains("TaskAnswerTextSelectionPolicy.completedAnswerMarkdownIsSelectable"))
        #expect(!completedAgentMarkdownView.contains(".textSelection(.enabled)"))
        #expect(streamingAgentTextView.contains("isSelectable: TaskAnswerTextSelectionPolicy.liveAnswerTextIsSelectable"))
        #expect(!streamingAgentTextView.contains(".textSelection(.enabled)"))
        #expect(listItemCase.contains("HStack(alignment: .top"))
        #expect(!listItemCase.contains("HStack(alignment: .firstTextBaseline"))
    }

    @Test("Repository protection artifacts stay wired")
    func repositoryProtectionArtifactsStayWired() throws {
        let root = try repositoryRoot()
        let requiredFiles = [
            ".github/workflows/ci.yml",
            ".github/workflows/memory-monitoring.yml",
            ".github/CODEOWNERS",
            ".githooks/pre-commit",
            ".githooks/pre-push",
            "script/focused_test_targets.sh",
            "script/focused_test_targets_tests.sh",
            "script/focused_validation_plan.sh",
            "script/focused_validation_plan_tests.sh",
            "script/precommit.sh",
            "script/prepush.sh",
            "script/record_memory_trace.sh",
            "script/test_architecture.sh",
            "script/test_git_contracts.sh",
            "script/configure_branch_protection.sh"
        ]

        for relativePath in requiredFiles {
            #expect(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path),
                "Missing repository protection artifact: \(relativePath)"
            )
        }

        for relativePath in requiredFiles.filter({ $0.hasPrefix(".githooks/") || $0.hasPrefix("script/") }) {
            #expect(
                try isExecutable(root.appendingPathComponent(relativePath)),
                "Protection script should be executable: \(relativePath)"
            )
        }

        let preCommitHook = try fileText(".githooks/pre-commit", root: root)
        let prePushHook = try fileText(".githooks/pre-push", root: root)
        let focusedTargetScript = try fileText("script/focused_test_targets.sh", root: root)
        let focusedValidationPlan = try fileText("script/focused_validation_plan.sh", root: root)
        let preCommitScript = try fileText("script/precommit.sh", root: root)
        let prePushScript = try fileText("script/prepush.sh", root: root)
        let branchProtectionScript = try fileText("script/configure_branch_protection.sh", root: root)
        let ciWorkflow = try fileText(".github/workflows/ci.yml", root: root)
        let memoryMonitoringWorkflow = try fileText(".github/workflows/memory-monitoring.yml", root: root)
        let memoryTraceScript = try fileText("script/record_memory_trace.sh", root: root)
        let codeowners = try fileText(".github/CODEOWNERS", root: root)
        let branchProtectionPayload = try branchProtectionJSONPayload(from: branchProtectionScript)
        let branchProtection = try #require(
            JSONSerialization.jsonObject(with: Data(branchProtectionPayload.utf8)) as? [String: Any]
        )
        let requiredStatusChecks = try #require(
            branchProtection["required_status_checks"] as? [String: Any]
        )
        let requiredContexts = try #require(requiredStatusChecks["contexts"] as? [String])

        #expect(preCommitHook.contains("script/precommit.sh"))
        #expect(prePushHook.contains("script/prepush.sh"))
        #expect(preCommitScript.contains("script/test_architecture.sh"))
        #expect(preCommitScript.contains("script/test_git_contracts.sh"))
        #expect(preCommitScript.contains("script/focused_validation_plan.sh"))
        #expect(preCommitScript.contains("script/focused_validation_plan_tests.sh"))
        #expect(preCommitScript.contains("script/focused_test_targets.sh"))
        #expect(preCommitScript.contains("script/focused_test_targets_tests.sh"))
        #expect(preCommitScript.contains(#"swift test --filter "$target""#))
        #expect(preCommitScript.contains(#"${#changed_files[@]} > 0"#))
        #expect(preCommitScript.contains("git diff --cached --check"))
        #expect(branchProtectionScript.contains(#""enforce_admins": false"#))
        #expect(requiredStatusChecks["strict"] as? Bool == true)
        #expect(requiredContexts == [
            "Focused Swift tests",
            "Full Swift test suite",
            "Whitespace"
        ])
        #expect(branchProtection["allow_fork_syncing"] as? Bool == false)
        #expect(focusedTargetScript.contains("Tools/MCPGatewaySupport"))
        #expect(focusedTargetScript.contains("MCPGatewaySupportTests"))
        #expect(focusedTargetScript.contains("Tools/MailToolSupport"))
        #expect(focusedTargetScript.contains("MailToolSupportTests"))
        #expect(focusedValidationPlan.contains("ASTRAGitContracts/*"))
        #expect(focusedValidationPlan.contains("Tests/ArchitectureFitnessTests/*"))
        #expect(focusedValidationPlan.contains("git-contracts"))
        #expect(focusedTargetScript.contains("AppSemanticFitnessTests"))
        #expect(prePushScript.contains("script/test_architecture.sh"))
        #expect(prePushScript.contains("script/test_git_contracts.sh"))
        #expect(prePushScript.contains("script/focused_validation_plan.sh"))
        #expect(prePushScript.contains("script/focused_validation_plan_tests.sh"))
        #expect(prePushScript.contains("script/focused_test_targets.sh"))
        #expect(prePushScript.contains("script/focused_test_targets_tests.sh"))
        #expect(prePushScript.contains("FOCUSED_SWIFT_TEST_FILTER="))
        #expect(prePushScript.components(separatedBy: "run swift test --filter").count == 3)
        #expect(prePushScript.contains(#"swift test --filter "$target""#))
        #expect(prePushScript.contains(#"${#changed_files[@]} > 0"#))
        #expect(prePushScript.contains("RuntimeReadinessServiceTests"))
        #expect(prePushScript.contains("WorkspacePersistenceTests"))
        #expect(prePushScript.contains("AgentRuntimeAdapterTests"))
        #expect(prePushScript.contains("git diff --no-ext-diff --check"))
        #expect(prePushScript.contains("git merge-base"))
        #expect(prePushScript.contains(#""${range}...HEAD""#))
        #expect(prePushScript.contains("origin/main...HEAD"))
        #expect(prePushScript.contains("git diff-tree --check --no-commit-id --root -r HEAD"))
        #expect(prePushScript.contains("changed_paths"))
        #expect(ciWorkflow.contains("actions/cache@v4"))
        #expect(ciWorkflow.contains("script/prepush.sh"))
        #expect(ciWorkflow.contains("Focused Swift tests"))
        #expect(ciWorkflow.contains("Full Swift test suite"))
        #expect(ciWorkflow.contains("workflow_dispatch:"))
        #expect(!ciWorkflow.contains("schedule:"))
        #expect(ciWorkflow.contains("swift test"))
        #expect(ciWorkflow.contains("fetch-depth: 0"))
        #expect(ciWorkflow.range(of: #"runs-on:\s+macos[-A-Za-z0-9_.]*"#, options: .regularExpression) != nil)
        #expect(ciWorkflow.contains("git diff --check"))
        #expect(memoryMonitoringWorkflow.contains("name: Memory Monitoring"))
        #expect(memoryMonitoringWorkflow.contains("workflow_dispatch:"))
        #expect(memoryMonitoringWorkflow.contains("schedule:"))
        #expect(memoryMonitoringWorkflow.contains("script/run_memory_stress.sh"))
        #expect(memoryMonitoringWorkflow.contains("MemoryLifecycleTests"))
        #expect(memoryMonitoringWorkflow.contains("GITHUB_STEP_SUMMARY"))
        #expect(memoryMonitoringWorkflow.contains("retention-days: 30"))
        #expect(memoryMonitoringWorkflow.contains("retention-days: 14"))
        #expect(memoryTraceScript.contains("/ASTRA Dev.app/Contents/MacOS/ASTRA Dev$"))
        #expect(memoryTraceScript.contains(#"*"/ASTRA Dev.app/Contents/MacOS/ASTRA Dev"*"#))
        #expect(!memoryTraceScript.contains("/ASTRA Dev.app/Contents/MacOS/ASTRA$"))
        #expect(!codeowners.contains("* @aandresalvarez"))
        #expect(codeowners.contains("Astra/Services/Runtime/"))
        #expect(codeowners.contains("Astra/Services/Persistence/"))
        #expect(codeowners.contains("Tests/ArchitectureFitnessTests/"))
        #expect(codeowners.contains("Tests/AppSemanticFitnessTests.swift"))
    }

    @Test("Remote MCP gateway tool policy exposes immutable policy lists")
    func remoteMCPGatewayToolPolicyExposesImmutablePolicyLists() throws {
        let root = try repositoryRoot()
        let source = try fileText("Tools/MCPGatewaySupport/MCPGatewaySupport.swift", root: root)
        let policy = try extractedStruct(named: "RemoteMCPGatewayToolPolicy", from: source)

        #expect(policy.contains("public let allowedTools: [String]"))
        #expect(policy.contains("public let excludedTools: [String]"))
        #expect(!policy.contains("public var allowedTools"))
        #expect(!policy.contains("public var excludedTools"))
    }

    @Test("Transcript worker idles without respawning an empty task loop")
    func transcriptWorkerRestartRequiresPendingWork() throws {
        let root = try repositoryRoot()
        let source = try fileText("Astra/Views/TaskThreadViewModel.swift", root: root)
        #expect(source.contains("if self.pendingSnapshotRequest != nil"))
        let protocolSource = try fileText("ASTRACore/AstraRunProtocol.swift", root: root)
        #expect(protocolSource.contains("visibleChunks.append"))
        #expect(!protocolSource.contains("visible += filter.process"))
    }

    private func taskStatusWriteViolations(
        in text: String,
        relativePath: String,
        taskStatusOwnerFiles: Set<String>
    ) -> [String] {
        guard !taskStatusOwnerFiles.contains(relativePath) else { return [] }

        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line in
                let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"),
                      let receiver = statusAssignmentReceiver(in: trimmed),
                      !isAllowedNonTaskStatusAssignment(receiver: receiver, relativePath: relativePath) else {
                    return nil
                }
                return "\(relativePath):\(index + 1): \(trimmed)"
            }
    }

    private func statusAssignmentReceiver(in line: String) -> String? {
        guard let assignmentRange = line.range(
            of: #"(?<![=!<>])=(?!=)"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let leftHandSide = line[..<assignmentRange.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        guard leftHandSide.hasSuffix(".status") else {
            return nil
        }

        return String(leftHandSide.dropLast(".status".count))
    }

    private func isAllowedNonTaskStatusAssignment(receiver: String, relativePath: String) -> Bool {
        allowedNonTaskStatusReceiversByFile[relativePath]?.contains(receiver) == true
    }

    private var allowedNonTaskStatusReceiversByFile: [String: Set<String>] {
        [
            "Astra/AppIntents/AstraAppEntities.swift": ["self"],
            "Astra/Models/TaskCorrectiveWork.swift": ["self"],
            "Astra/Models/TaskDeliverableVerification.swift": ["self"],
            "Astra/Models/TaskMissionHardening.swift": ["self"],
            "Astra/Models/TaskPlan.swift": ["self"],
            "Astra/Models/TaskResourceLock.swift": ["self"],
            "Astra/Models/TaskRun.swift": ["self"],
            "Astra/Models/TaskSchedule.swift": ["self"],
            "Astra/Models/TaskValidationContract.swift": ["self"],
            "Astra/Services/Capabilities/MCPControlPlaneRuntimeBindingService.swift": ["self"],
            "Astra/Services/Persistence/SessionScanner.swift": ["run"],
            "Astra/Services/Persistence/TaskContextStateManager.swift": ["self"],
            "Astra/Services/Persistence/WorkspaceConfigManager.swift": ["run"],
            "Astra/Services/Runtime/AgentProcessSupport.swift": ["job"],
            "Astra/Services/Runtime/AgentRuntimeBudgetPolicy.swift": ["run"],
            "Astra/Services/Runtime/AgentRuntimeCapabilityBlockRecorder.swift": ["run"],
            "Astra/Services/Runtime/AgentRuntimeLaunchPreflight.swift": ["run"],
            "Astra/Services/Runtime/AgentRuntimeWorker.swift": ["run", "run?"],
            "Astra/Models/AgentTaskForkService.swift": ["newRun"],
            "Astra/Services/Tasks/DatabaseQueryService.swift": ["self"],
            "Astra/Services/Tasks/TaskPlanService.swift": ["plan.steps[index]", "merged.steps[index]"],
            "Astra/Services/Tasks/TaskPlanStateCacheSignature.swift": ["self"],
            "Astra/Services/Tasks/TaskQueue.swift": ["copiedRun"],
            "Astra/Services/Tasks/TaskRunLifecycleService.swift": ["run"],
            "Astra/Services/Validation/TaskCorrectiveWorkService.swift": ["payload"],
            "Astra/Services/WorkspaceApps/WorkspaceAppActionExecutor.swift": ["run"],
            "Astra/Services/WorkspaceApps/WorkspaceAppAutomationExecutionService.swift": ["state"],
            "Astra/Services/WorkspaceApps/WorkspaceAppAutomationScheduler.swift": ["automation"],
            "Astra/Services/WorkspaceApps/WorkspaceAppRunResumptionService.swift": ["run"],
            "Astra/Services/WorkspaceApps/WorkspaceAppService.swift": ["automation", "binding", "surviving"],
            "Astra/Views/Components/KanbanBoardView.swift": ["self"],
            "Astra/Views/RunActivityPresentation.swift": ["response"],
            "Astra/Views/WorkspaceRightRailCapabilitySnapshotCache.swift": ["self"]
        ]
    }

    private enum LineBudgetClassification: Equatable {
        case owner(String)
        case companion(of: String)
    }

    private struct LineBudgetEntry {
        let budget: Int
        let classification: LineBudgetClassification

        init(_ budget: Int, _ classification: LineBudgetClassification) {
            self.budget = budget
            self.classification = classification
        }
    }

    private var lineBudgetThreshold: Int { 2_000 }

    private var lineBudgetRegistry: [String: LineBudgetEntry] {
        [
            "Astra/Views/TaskMainView.swift": .init(6_100, .owner("Task detail and run surface")),
            "Astra/Services/Browser/ShelfBrowserSession.swift": .init(6_000, .owner("Shelf browser session")),
            // Budget raised for issues #322/#323 plus PR #328: the
            // zero-workspace titlebar command flag, the portable-package
            // import surface (one @State, one sheet, URL partition in
            // importWorkspace), and the durable external-operation wiring
            // (monitor lifecycle, trusted-receipt adoption ordering, and
            // delete/replace cancel-and-verify outcome handling) — the
            // review UI, import logic, and operation services themselves
            // live in their own files.
            "Astra/Views/ContentView.swift": .init(4_930, .owner("Workspace shell composition")),
            // Budget raised for the V11 freeze / V12 mint (AgentTask.runtimeExplicitlySelected):
            // freezing a schema version means copying every one of its ~16
            // referenced model types into a fully self-contained nested body
            // (957a90a8's V10 freeze is the precedent), which grows this file
            // by ~450-500 lines every time. That growth is expected schema
            // history, not scope creep - there's nothing to shrink here.
            "Astra/Models/SchemaVersions.swift": .init(4_100, .owner("SwiftData schema history")),
            // Budget raised to propagate AgentTask.runtimeExplicitlySelected through
            // this composer's draft lifecycle: the flag has to be set/preserved at
            // every one of its task-creation and draft-resync call sites (quickRun,
            // createTaskFromSpec, runApprovedPlan, saveDraft's two branches) plus a
            // couple of session-reset points, so the growth is spread thin by design
            // rather than concentrated in one function that could be extracted.
            "Astra/Views/ChatPanelView.swift": .init(3_075, .owner("Composer chat surface")),
            "Astra/Services/Runtime/AgentRuntimeAdapter.swift": .init(2_900, .owner("Runtime adapter registry")),
            "Astra/Views/PluginCatalogView.swift": .init(2_900, .owner("Capability catalog UI")),
            "Astra/Views/ShelfMarkdownPanelView.swift": .init(2_850, .owner("Shelf markdown panel")),
            // Budget raised for Track A4 (ASTRAPersistence extraction): every
            // public struct now needs an explicit `public init` (Swift's
            // synthesized memberwise init is always internal, even for an
            // all-public struct) to stay constructible from outside this new
            // target - a hard language requirement, not scope creep.
            // + PR #328: remappingTaskIdentities (fresh AgentTask/TaskRun ids
            // for duplicated workspaces so a duplicate can't drive the
            // original's globally-taskID-keyed external operations), including
            // the Workspace App run task references (linkedTaskID +
            // awaitedTaskIDsJSON) resolved globally by run resumption.
            "Astra/Services/Persistence/WorkspaceConfigManager.swift": .init(3_340, .owner("Workspace mirror persistence")),
            "Astra/Views/ConfigureView.swift": .init(2_600, .owner("Legacy configure surface")),
            "Astra/Services/Diagnostics/LogDiagnosticsService.swift": .init(2_600, .owner("Log diagnostics")),
            // Self-referential: this file crossed its own 2,000-line
            // threshold from the file-access-broker tests added for issue
            // #323's WorkspacePackage subsystem. It's a flat suite, not a
            // companion of one production file, so it owns itself here.
            "Tests/ArchitectureFitnessTests/ArchitectureFitnessTests.swift": .init(2_150, .owner("Architecture fitness test suite")),
            // Budget raised for issue #322: the Routines section, sort/star-filter
            // controls, and empty-state copy each need their own gate — three
            // call sites, not one boundary to extract.
            "Astra/Views/TaskSidebarView.swift": .init(2_510, .owner("Task sidebar")),
            "Astra/Services/WorkspaceApps/WorkspaceAppActionExecutor.swift": .init(2_450, .owner("Workspace App action execution")),
            "Astra/Views/WorkspaceRightRailView.swift": .init(2_400, .owner("Workspace right rail")),
            // Budget raised for Track A4 (ASTRAPersistence extraction) - see
            // WorkspaceConfigManager.swift's entry above for why.
            "Astra/Services/Persistence/TaskContextStateManager.swift": .init(2_450, .owner("Task context state")),
            "Astra/Views/ShelfQueryPanelView.swift": .init(2_300, .owner("Shelf query panel")),
            "Astra/Services/Runtime/AgentPromptBuilder.swift": .init(2_300, .owner("Provider prompt assembly")),
            "Astra/Services/Browser/BrowserAnalysis.swift": .init(2_150, .owner("Browser analysis")),
            "Astra/Services/Runtime/AgentProcessSupport.swift": .init(2_150, .owner("Runtime process stream support")),
            "Astra/Services/Browser/ControlledBrowserController.swift": .init(2_100, .owner("Controlled browser orchestration")),
            // External-operation wakes disable reuse at the private continuation decision boundary.
            // + PR #328: failure-reasoning wakes bypass ordinary success
            // validation (deliverables/runTests/aiCheck) so a resume-phase
            // validation failure can't pre-empt the external-outcome review,
            // and isolation is retained until every terminal wake finishes.
            "Astra/Services/Runtime/AgentRuntimeWorker.swift": .init(2_260, .owner("Runtime worker execution")),
            "Tools/WorkspaceToolSupport/WorkspaceToolSupport.swift": .init(3_450, .owner("Workspace MCP tool")),
            "Tools/HostControlToolSupport/HostControlToolSupport.swift": .init(2_250, .owner("Host-control MCP tool")),
            "Tests/ProcessMonitorTests.swift": .init(3_500, .companion(of: "Astra/Services/Runtime/AgentProcessSupport.swift")),
            "Tests/TaskCapabilityResolverTests.swift": .init(2_950, .companion(of: "Astra/Services/Runtime/AgentRuntimeAdapter.swift")),
            // Bumped 3_200 -> 3_201 for Track A2 (Models -> Runtime edge break: moved
            // WorkspaceExecutionEnvironment/ConnectorSecurityPolicy value types to ASTRACore
            // and seamed the two Runtime-specific reads; the load-bearing Runtime -> Models
            // direction in Finding 2 of the extraction doc is untouched and remains its own
            // dedicated PR — see docs/architecture/swiftpm-target-extraction-models-persistence.md).
            "Tests/AgentRuntimeAdapterTests.swift": .init(3_350, .companion(of: "Astra/Services/Runtime/AgentRuntimeAdapter.swift")),
            "Tests/AgentRuntimeWorkerTests.swift": .init(2_550, .companion(of: "Astra/Services/Runtime/AgentRuntimeAdapter.swift")),
            "Tests/AgentPolicyTests.swift": .init(2_650, .companion(of: "Astra/Services/Runtime/AgentRuntimeAdapter.swift")),
            "Tests/WorkspaceAppActionExecutorTests.swift": .init(2_500, .companion(of: "Astra/Services/WorkspaceApps/WorkspaceAppActionExecutor.swift")),
            // Budget raised for runtimeExplicitlySelected export/import round-trip
            // coverage (PR #281 review follow-up) - two new tests matching this
            // file's existing verbose per-field TaskConfig(...) construction style,
            // then again for PR #328's replace-refused-while-external-work-active
            // regression (both replace paths exercised against a live registration).
            "Tests/WorkspacePersistenceTests.swift": .init(2_900, .companion(of: "Astra/Services/Persistence/WorkspaceConfigManager.swift")),
            "Tests/CopilotRuntimeTests.swift": .init(2_300, .companion(of: "Astra/Services/Runtime/AgentRuntimeAdapter.swift")),
            "Tests/WorkspaceAppPackageTests.swift": .init(2_250, .companion(of: "Astra/Services/WorkspaceApps/WorkspaceAppActionExecutor.swift")),
            // Durable job trust, restart, cleanup, and filesystem attacks stay at the tool boundary.
            "Tests/WorkspaceToolSupportTests.swift": .init(2_476, .companion(of: "Tools/WorkspaceToolSupport/WorkspaceToolSupport.swift")),
            // Bumped 2_100 -> 2_150 for the Cursor/Antigravity autonomous-mode
            // Keychain-read grant: one kernel-verified readable-roots test per
            // runtime (mirrors the existing Claude Code auth-readable-roots test).
            "Tests/ExecutionSandboxTests.swift": .init(2_150, .companion(of: "Astra/Services/Runtime/AgentRuntimeAdapter.swift")),
            "Tests/HostControlToolSupportTests.swift": .init(2_100, .companion(of: "Tools/HostControlToolSupport/HostControlToolSupport.swift"))
        ]
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
                throw ArchitectureFitnessError.repositoryRootNotFound(FileManager.default.currentDirectoryPath)
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

    private func lineCount(for file: URL) throws -> Int {
        let text = try String(contentsOf: file, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private func occurrenceCount(pattern: String, files: [URL]) throws -> Int {
        try files.reduce(0) { total, file in
            let text = try String(contentsOf: file, encoding: .utf8)
            return total + text.components(separatedBy: pattern).count - 1
        }
    }

    private func fileText(_ relativePath: String, root: URL) throws -> String {
        try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func branchProtectionJSONPayload(from script: String) throws -> String {
        guard let start = script.range(of: "<<'JSON'\n") else {
            throw ArchitectureFitnessError.sourceSnippetNotFound("branch protection JSON start")
        }
        guard let end = script[start.upperBound...].range(of: "\nJSON") else {
            throw ArchitectureFitnessError.sourceSnippetNotFound("branch protection JSON end")
        }
        return String(script[start.upperBound..<end.lowerBound])
    }

    private func regexCaptures(_ pattern: String, in text: String, captureGroup: Int = 1) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > captureGroup,
                  let range = Range(match.range(at: captureGroup), in: text) else {
                return nil
            }
            return String(text[range])
        }
    }

    private func extractedStruct(named name: String, from source: String) throws -> String {
        guard let declarationRange = source.range(of: "struct \(name)") else {
            throw ArchitectureFitnessError.sourceSnippetNotFound(name)
        }
        guard let openingBrace = source[declarationRange.lowerBound...].firstIndex(of: "{") else {
            throw ArchitectureFitnessError.sourceSnippetNotFound(name)
        }

        var depth = 0
        var index = openingBrace
        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[declarationRange.lowerBound...index])
                }
            default:
                break
            }
            index = source.index(after: index)
        }

        throw ArchitectureFitnessError.sourceSnippetNotFound(name)
    }

    private func isExecutable(_ file: URL) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            return false
        }
        return permissions.intValue & 0o111 != 0
    }
}

private enum ArchitectureFitnessError: Error {
    case repositoryRootNotFound(String)
    case sourceSnippetNotFound(String)
}
