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
            "Git",
            "GoogleWorkspace",
            "Packs",
            "Persistence",
            "Runtime",
            "Security",
            "Settings",
            "Shelves",
            "Tasks",
            "Validation",
            "WorkspaceApps"
        ])
    }

    @Test("Pack services stay in the Packs service folder")
    func packServicesStayInPacksServiceFolder() throws {
        let root = try repositoryRoot()
        let serviceRoot = root.appendingPathComponent("Astra/Services")
        let allowedWorkspaceAppPackAdapters: Set<String> = [
            "Astra/Services/WorkspaceApps/WorkspaceAppTemplatePackCatalog.swift"
        ]
        let packServiceFilesOutsidePacks = try swiftFiles(under: serviceRoot)
            .compactMap { file -> String? in
                let path = relativePath(for: file, root: root)
                guard path.contains("/Packs/") == false else { return nil }
                guard allowedWorkspaceAppPackAdapters.contains(path) == false else { return nil }
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

    @Test("Production task status writes go through TaskStateMachine")
    func productionTaskStatusWritesGoThroughTaskStateMachine() throws {
        let root = try repositoryRoot()
        let allowedFiles: Set<String> = [
            "Astra/Models/AgentTask.swift",
            "Astra/Models/SchemaVersions.swift",
            "Astra/Services/Tasks/TaskStateMachine.swift"
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
            "Astra/Services/Runtime/ExecutionSandbox.swift",
            "Astra/Services/Security/HostFileAccessBroker.swift",
            "Astra/Services/Security/PrivacySensitivePathPolicy.swift"
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

    @Test("Large owner files stay within current debt budgets")
    func largeOwnerFilesStayWithinCurrentDebtBudgets() throws {
        let root = try repositoryRoot()
        let lineBudgets = [
            "Astra/Views/TaskMainView.swift": 6_900,
            "Astra/Services/Browser/ShelfBrowserSession.swift": 5_900,
            "Astra/Views/ContentView.swift": 5_000,
            "Astra/Views/WorkspaceRightRailView.swift": 3_500,
            "Astra/Views/ChatPanelView.swift": 3_215,
            "Astra/Services/Runtime/AgentRuntimeAdapter.swift": 2_940,
            "Astra/Views/PluginCatalogView.swift": 2_900,
            "Astra/Views/ShelfMarkdownPanelView.swift": 2_850,
            "Astra/Views/WorkspaceGitSectionView.swift": 2_650,
            "Astra/Views/ConfigureView.swift": 2_550,
            "Astra/Services/Diagnostics/LogDiagnosticsService.swift": 2_550,
            "Astra/Views/TaskSidebarView.swift": 2_465,
            "Astra/Views/ShelfQueryPanelView.swift": 2_350,
            "Astra/Services/Persistence/TaskContextStateManager.swift": 2_250,
            "Astra/Services/Runtime/AgentPromptBuilder.swift": 2_250,
            "Astra/Views/OnboardingWizardView.swift": 2_250,
            "Astra/Services/Runtime/AgentProcessSupport.swift": 2_100,
            "Astra/Services/Browser/BrowserAnalysis.swift": 2_100,
            "Astra/Services/Git/GitService.swift": 2_100,
            "Astra/Services/Runtime/AgentRuntimeWorker.swift": 2_100,
            "Astra/Services/Browser/ControlledBrowserController.swift": 2_050,
            "Astra/Views/ShelfBrowserPanelView.swift": 2_050
        ]

        let violations = try lineBudgets.compactMap { relativePath, budget -> String? in
            let count = try lineCount(for: root.appendingPathComponent(relativePath))
            return count > budget ? "\(relativePath): \(count) > \(budget)" : nil
        }

        #expect(
            violations.isEmpty,
            "Large owner files should shrink or move behind focused boundaries instead of growing: \(violations.sorted())"
        )
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
        #expect(streamingAgentTextView.contains("taskAnswerTextSelection(TaskAnswerTextSelectionPolicy.liveAnswerTextIsSelectable)"))
        #expect(!streamingAgentTextView.contains(".textSelection(.enabled)"))
        #expect(listItemCase.contains("HStack(alignment: .top"))
        #expect(!listItemCase.contains("HStack(alignment: .firstTextBaseline"))
    }

    @Test("Repository protection artifacts stay wired")
    func repositoryProtectionArtifactsStayWired() throws {
        let root = try repositoryRoot()
        let requiredFiles = [
            ".github/workflows/ci.yml",
            ".github/CODEOWNERS",
            ".githooks/pre-commit",
            ".githooks/pre-push",
            "script/focused_test_targets.sh",
            "script/focused_test_targets_tests.sh",
            "script/precommit.sh",
            "script/prepush.sh",
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
        let preCommitScript = try fileText("script/precommit.sh", root: root)
        let prePushScript = try fileText("script/prepush.sh", root: root)
        let branchProtectionScript = try fileText("script/configure_branch_protection.sh", root: root)
        let ciWorkflow = try fileText(".github/workflows/ci.yml", root: root)
        let codeowners = try fileText(".github/CODEOWNERS", root: root)

        #expect(preCommitHook.contains("script/precommit.sh"))
        #expect(prePushHook.contains("script/prepush.sh"))
        #expect(preCommitScript.contains("swift test --filter ArchitectureFitnessTests.ArchitectureFitnessTests"))
        #expect(preCommitScript.contains("script/focused_test_targets.sh"))
        #expect(preCommitScript.contains("script/focused_test_targets_tests.sh"))
        #expect(preCommitScript.contains(#"swift test --filter "$target""#))
        #expect(preCommitScript.contains(#"${#changed_files[@]} > 0"#))
        #expect(preCommitScript.contains("git diff --cached --check"))
        #expect(branchProtectionScript.contains(#""enforce_admins": false"#))
        #expect(focusedTargetScript.contains("Tools/MCPGatewaySupport"))
        #expect(focusedTargetScript.contains("MCPGatewaySupportTests"))
        #expect(focusedTargetScript.contains("Tools/MailToolSupport"))
        #expect(focusedTargetScript.contains("MailToolSupportTests"))
        #expect(focusedTargetScript.contains("Tests/ArchitectureFitnessTests/*"))
        #expect(focusedTargetScript.contains("AppSemanticFitnessTests"))
        #expect(prePushScript.contains("script/focused_test_targets.sh"))
        #expect(prePushScript.contains("script/focused_test_targets_tests.sh"))
        #expect(prePushScript.contains("FOCUSED_SWIFT_TEST_FILTER="))
        #expect(prePushScript.components(separatedBy: "run swift test --filter").count == 3)
        #expect(prePushScript.contains(#"swift test --filter "$target""#))
        #expect(prePushScript.contains(#"${#changed_files[@]} > 0"#))
        #expect(prePushScript.contains("ArchitectureFitnessTests"))
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
        #expect(ciWorkflow.contains("schedule:"))
        #expect(ciWorkflow.contains("swift test"))
        #expect(ciWorkflow.contains("fetch-depth: 0"))
        #expect(ciWorkflow.range(of: #"runs-on:\s+macos[-A-Za-z0-9_.]*"#, options: .regularExpression) != nil)
        #expect(ciWorkflow.contains("git diff --check"))
        #expect(!codeowners.contains("* @aandresalvarez"))
        #expect(codeowners.contains("Astra/Services/Runtime/"))
        #expect(codeowners.contains("Astra/Services/Persistence/"))
        #expect(codeowners.contains("Tests/ArchitectureFitnessTests/"))
        #expect(codeowners.contains("Tests/AppSemanticFitnessTests.swift"))
    }

    @Test("Architecture fitness checks run in a standalone test target")
    func architectureFitnessChecksRunInStandaloneTestTarget() throws {
        let root = try repositoryRoot()
        let package = try fileText("Package.swift", root: root)
        let testFile = try fileText("Tests/ArchitectureFitnessTests/ArchitectureFitnessTests.swift", root: root)
        let codeowners = try fileText(".github/CODEOWNERS", root: root)
        let disallowedAppImport = "@testable import " + "ASTRA"
        let disallowedSwiftDataImport = "import " + "SwiftData"

        #expect(package.contains(#"name: "ArchitectureFitnessTests""#))
        #expect(package.contains(#"exclude: ["ArchitectureFitnessTests""#))
        #expect(!testFile.contains(disallowedAppImport))
        #expect(!testFile.contains(disallowedSwiftDataImport))
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
            "Astra/Models/TaskPlan.swift": ["self"],
            "Astra/Models/TaskRun.swift": ["self"],
            "Astra/Services/Capabilities/MCPControlPlaneRuntimeBindingService.swift": ["self"],
            "Astra/Services/Persistence/SessionScanner.swift": ["run"],
            "Astra/Services/Persistence/TaskContextStateManager.swift": ["self"],
            "Astra/Services/Persistence/WorkspaceConfigManager.swift": ["run"],
            "Astra/Services/Runtime/AgentProcessSupport.swift": ["job"],
            "Astra/Services/Runtime/AgentRuntimeBudgetPolicy.swift": ["run"],
            "Astra/Services/Runtime/AgentRuntimeLaunchPreflight.swift": ["run"],
            "Astra/Services/Runtime/AgentRuntimeWorker.swift": ["run", "run?"],
            "Astra/Services/Tasks/AgentTaskForkService.swift": ["newRun"],
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
