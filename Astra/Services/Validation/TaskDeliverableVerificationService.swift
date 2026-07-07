import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence
import ASTRACore

enum JavaScriptSyntaxCheckResult: Sendable, Equatable {
    case passed
    case failed(String)
    case unavailable(String)
}

struct TaskDeliverableVerificationEnvironment: Sendable {
    var checkJavaScriptSyntax: @Sendable (_ source: String, _ sourceLabel: String) async -> JavaScriptSyntaxCheckResult

    static let live = TaskDeliverableVerificationEnvironment(
        checkJavaScriptSyntax: { source, sourceLabel in
            await TaskDeliverableVerificationService.checkJavaScriptSyntaxWithNode(
                source: source,
                sourceLabel: sourceLabel
            )
        }
    )
}

enum TaskDeliverableVerificationService {
    private static let maxInspectableBytes: UInt64 = 2 * 1024 * 1024

    @MainActor
    static func evaluate(
        task: AgentTask,
        run: TaskRun?,
        modelContext: ModelContext? = nil,
        environment: TaskDeliverableVerificationEnvironment = .live
    ) async -> TaskDeliverableVerificationResult {
        let requiredFilenames = TaskDeliverableExpectation.requiredOutputFilenames(task)
        let requiresDeliverableArtifact = TaskDeliverableExpectation.requiresDeliverableArtifact(
            task,
            requiredOutputFilenames: requiredFilenames
        )
        let discoveredFiles = TaskOutputDiscovery.files(for: task, run: run)
        let artifactReconciliation = TaskArtifactPersistenceService.reconcileTaskOutputArtifacts(
            discoveredFiles,
            for: task,
            modelContext: modelContext
        )
        let files = artifactReconciliation.discoveredFiles
        let profile = profile(for: task, files: files, requiresArtifact: requiresDeliverableArtifact)

        guard requiresDeliverableArtifact || !files.isEmpty else {
            return result(
                profile: .notRequired,
                level: .notApplicable,
                status: "not_applicable",
                canComplete: true,
                requiresHumanReview: false,
                summary: "No standalone deliverable was required.",
                checks: [],
                evidencePaths: [],
                run: run
            )
        }

        guard !files.isEmpty else {
            return result(
                profile: profile,
                level: .noArtifact,
                status: "failed",
                canComplete: false,
                requiresHumanReview: false,
                summary: TaskDeliverableExpectation.missingDeliverableMessage(
                    for: task,
                    requiredFilenames: requiredFilenames
                ),
                checks: [
                    TaskDeliverableCheck(
                        id: "artifact.discovery",
                        title: "Artifact discovery",
                        status: .failed,
                        summary: "No displayable task output artifact was found.",
                        path: nil
                    )
                ] + requiredFileChecks(requiredFilenames: requiredFilenames, discoveredFilenames: []),
                evidencePaths: [],
                run: run
            )
        }

        var checks: [TaskDeliverableCheck] = [
            TaskDeliverableCheck(
                id: "artifact.discovery",
                title: "Artifact discovery",
                status: .passed,
                summary: "\(files.count) displayable task output artifact\(files.count == 1 ? "" : "s") found.",
                path: nil
            )
        ]
        if !requiredFilenames.isEmpty {
            let discoveredFilenames = Set(files.map { URL(fileURLWithPath: $0.path).lastPathComponent.lowercased() })
            checks.append(contentsOf: requiredFileChecks(
                requiredFilenames: requiredFilenames,
                discoveredFilenames: discoveredFilenames
            ))
        }

        let hostFileAccess = HostFileAccessBroker()
        let taskAccess = TaskWorkspaceAccess(task: task)
        let artifactRoots = [taskAccess.taskFolder, taskAccess.effectiveWorkspacePath]
            .filter { !$0.isEmpty }
        for file in files.prefix(12) {
            let artifactRoot = artifactRoot(for: file, allowedRoots: artifactRoots)
                ?? URL(fileURLWithPath: taskAccess.taskFolder, isDirectory: true)
            checks.append(contentsOf: await checksForFile(
                file,
                environment: environment,
                hostFileAccess: hostFileAccess,
                artifactRoot: artifactRoot
            ))
        }

        let hasFailure = checks.contains { $0.status == .failed }
        let hasSyntaxPass = checks.contains { $0.id.contains("syntax") && $0.status == .passed }
        let needsReview = checks.contains { $0.status == .warning || $0.status == .skipped }
        let level: TaskDeliverableQualityLevel
        let status: String
        let canComplete: Bool
        let requiresHumanReview: Bool

        if hasFailure {
            level = .failed
            status = "failed"
            canComplete = false
            requiresHumanReview = false
        } else if hasSyntaxPass {
            level = .syntaxVerified
            status = needsReview ? "review_needed" : "passed"
            canComplete = true
            requiresHumanReview = needsReview
        } else if needsReview {
            level = .needsHumanReview
            status = "review_needed"
            canComplete = true
            requiresHumanReview = true
        } else {
            level = .artifactOnly
            status = "review_needed"
            canComplete = true
            requiresHumanReview = true
        }

        return result(
            profile: profile,
            level: level,
            status: status,
            canComplete: canComplete,
            requiresHumanReview: requiresHumanReview,
            summary: summary(for: level, fileCount: files.count, checks: checks),
            checks: checks,
            evidencePaths: files.map(\.path),
            run: run
        )
    }

    static func eventType(for result: TaskDeliverableVerificationResult) -> String? {
        switch result.status {
        case "passed":
            return TaskDeliverableVerificationEventTypes.passed
        case "review_needed":
            return TaskDeliverableVerificationEventTypes.reviewNeeded
        case "failed":
            return TaskDeliverableVerificationEventTypes.failed
        default:
            return nil
        }
    }

    static func encode(_ result: TaskDeliverableVerificationResult) -> String {
        let payload = TaskDeliverableVerificationEventPayload(
            version: result.version,
            profile: result.profile,
            level: result.level,
            status: result.status,
            canComplete: result.canComplete,
            requiresHumanReview: result.requiresHumanReview,
            summary: result.summary,
            checks: result.checks,
            evidencePaths: result.evidencePaths,
            runID: result.runID,
            verifiedAt: result.verifiedAt
        )
        return TaskEvent.payloadString(
            payload,
            fallback: result.summary,
            encoder: TaskEventPayloadCodec.makeISO8601Encoder()
        )
    }

    static func decode(_ payload: String) -> TaskDeliverableVerificationEventPayload? {
        TaskDeliverableVerificationCodec.decode(payload)
    }

    static func decodeResult(
        _ payload: String
    ) -> Result<TaskDeliverableVerificationEventPayload, TaskEventPayloadDecodeError> {
        TaskDeliverableVerificationCodec.decodeResult(payload)
    }

    static func checkJavaScriptSyntaxWithNode(
        source: String,
        sourceLabel: String
    ) async -> JavaScriptSyntaxCheckResult {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("astra-js-syntax-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let sourceURL = directory.appendingPathComponent("check.js")
            try source.write(to: sourceURL, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", "--check", sourceURL.path]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "") + ":\(RuntimePathResolver.shellPathSuffix)"
            process.environment = env

            let stdoutURL = directory.appendingPathComponent("stdout.txt")
            let stderrURL = directory.appendingPathComponent("stderr.txt")
            _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            let output = await runSyntaxProcess(
                process,
                stdoutURL: stdoutURL,
                stderrURL: stderrURL,
                timeoutSeconds: 5,
                sourceLabel: sourceLabel
            )
            if output.exitCode == 0 {
                return .passed
            }
            let detail = [output.stderr, output.stdout]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            if output.exitCode == -1 {
                return .unavailable(detail.isEmpty ? "Could not run JavaScript syntax check for \(sourceLabel)." : detail)
            }
            if output.exitCode == 127 || detail.lowercased().contains("no such file") {
                return .unavailable("Node.js is not available to syntax-check \(sourceLabel).")
            }
            return .failed(detail.isEmpty ? "JavaScript syntax check failed for \(sourceLabel)." : detail)
        } catch {
            return .unavailable("Could not run JavaScript syntax check for \(sourceLabel): \(error.localizedDescription)")
        }
    }

    private struct SyntaxProcessOutput: Sendable {
        var exitCode: Int
        var stdout: String
        var stderr: String
    }

    private final class SyntaxProcessState: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func finish() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return false }
            completed = true
            return true
        }
    }

    private static func runSyntaxProcess(
        _ process: Process,
        stdoutURL: URL,
        stderrURL: URL,
        timeoutSeconds: TimeInterval,
        sourceLabel: String
    ) async -> SyntaxProcessOutput {
        let state = SyntaxProcessState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let stdoutHandle: FileHandle
                let stderrHandle: FileHandle
                do {
                    stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
                    stderrHandle = try FileHandle(forWritingTo: stderrURL)
                } catch {
                    continuation.resume(returning: SyntaxProcessOutput(
                        exitCode: -1,
                        stdout: "",
                        stderr: "Could not create JavaScript syntax check output files for \(sourceLabel): \(error.localizedDescription)"
                    ))
                    return
                }

                process.standardOutput = stdoutHandle
                process.standardError = stderrHandle
                process.terminationHandler = { proc in
                    guard state.finish() else { return }
                    try? stdoutHandle.close()
                    try? stderrHandle.close()
                    continuation.resume(returning: SyntaxProcessOutput(
                        exitCode: Int(proc.terminationStatus),
                        stdout: readSyntaxOutput(stdoutURL),
                        stderr: readSyntaxOutput(stderrURL)
                    ))
                }

                do {
                    try process.run()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                        guard state.finish() else { return }
                        AsyncProcessRunner.terminateProcessTree(process)
                        try? stdoutHandle.close()
                        try? stderrHandle.close()
                        continuation.resume(returning: SyntaxProcessOutput(
                            exitCode: -1,
                            stdout: readSyntaxOutput(stdoutURL),
                            stderr: "JavaScript syntax check timed out for \(sourceLabel)."
                        ))
                    }
                } catch {
                    guard state.finish() else { return }
                    try? stdoutHandle.close()
                    try? stderrHandle.close()
                    continuation.resume(returning: SyntaxProcessOutput(
                        exitCode: -1,
                        stdout: "",
                        stderr: error.localizedDescription
                    ))
                }
            }
        } onCancel: {
            AsyncProcessRunner.terminateProcessTree(process)
        }
    }

    private static func readSyntaxOutput(_ url: URL) -> String {
        let hostFileAccess = HostFileAccessBroker()
        guard let data = try? hostFileAccess.readData(
            at: url,
            intent: .astraManagedStorage(root: url.deletingLastPathComponent())
        ),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func result(
        profile: TaskDeliverableProfile,
        level: TaskDeliverableQualityLevel,
        status: String,
        canComplete: Bool,
        requiresHumanReview: Bool,
        summary: String,
        checks: [TaskDeliverableCheck],
        evidencePaths: [String],
        run: TaskRun?
    ) -> TaskDeliverableVerificationResult {
        TaskDeliverableVerificationResult(
            version: 1,
            profile: profile,
            level: level,
            status: status,
            canComplete: canComplete,
            requiresHumanReview: requiresHumanReview,
            summary: bounded(summary, maxCharacters: 700),
            checks: checks.map {
                TaskDeliverableCheck(
                    id: bounded($0.id, maxCharacters: 80),
                    title: bounded($0.title, maxCharacters: 120),
                    status: $0.status,
                    summary: bounded($0.summary, maxCharacters: 500),
                    path: $0.path
                )
            },
            evidencePaths: Array(evidencePaths.prefix(20)),
            runID: run?.id,
            verifiedAt: Date()
        )
    }

    private static func profile(
        for task: AgentTask,
        files: [TaskOutputDiscoveredFile],
        requiresArtifact: Bool
    ) -> TaskDeliverableProfile {
        guard requiresArtifact || !files.isEmpty else { return .notRequired }
        let text = [
            task.title,
            task.goal,
            task.inputs.joined(separator: " "),
            task.acceptanceCriteria.joined(separator: " ")
        ]
            .joined(separator: " ")
            .lowercased()
        let kinds = Set(files.map(\.kind))
        if kinds.contains(.html) || text.contains("web page") || text.contains("webpage") || text.contains("javascript") {
            return .standaloneWebArtifact
        }
        if !kinds.isDisjoint(with: ["md", .markdown, .text, .pdf, .doc, .docx, .rtf]) ||
            text.contains("document") || text.contains("report") || text.contains("requirements") {
            return .documentArtifact
        }
        if !kinds.isDisjoint(with: [.javascript, "mjs", "cjs", .typescript, .tsx, .jsx, .swift, .python, "rb", "go", "rs"]) ||
            text.contains("script") || text.contains("code") {
            return .codeArtifact
        }
        if !kinds.isDisjoint(with: [.json, .csv, .tsv, .sql, .yaml, .yml]) ||
            text.contains("data") || text.contains("csv") || text.contains("json") {
            return .dataArtifact
        }
        return .genericArtifact
    }

    private static func checksForFile(
        _ file: TaskOutputDiscoveredFile,
        environment: TaskDeliverableVerificationEnvironment,
        hostFileAccess: HostFileAccessBroker,
        artifactRoot: URL
    ) async -> [TaskDeliverableCheck] {
        guard let size = fileSize(file.path), size > 0 else {
            return [
                TaskDeliverableCheck(
                    id: "artifact.nonempty",
                    title: "Artifact content",
                    status: .failed,
                    summary: "Artifact is empty.",
                    path: file.path
                )
            ]
        }
        guard size <= maxInspectableBytes else {
            return [
                TaskDeliverableCheck(
                    id: "artifact.size",
                    title: "Artifact size",
                    status: .warning,
                    summary: "Artifact is \(size) bytes; deterministic content probes skip files over \(maxInspectableBytes) bytes.",
                    path: file.path
                )
            ]
        }

        let ext = URL(fileURLWithPath: file.path).pathExtension.lowercased()
        let intent = HostFileAccessIntent.astraManagedStorage(root: artifactRoot)
        switch ext {
        case "html", "htm":
            return await htmlChecks(
                file,
                environment: environment,
                hostFileAccess: hostFileAccess,
                intent: intent
            )
        case "js", "mjs", "cjs":
            return await javascriptChecks(
                file,
                environment: environment,
                hostFileAccess: hostFileAccess,
                intent: intent
            )
        case "json":
            return jsonChecks(file, hostFileAccess: hostFileAccess, intent: intent)
        case "md", "markdown", "txt", "csv", "tsv", "sql", "css", "svg", "xml", "yaml", "yml":
            return readableTextChecks(file, hostFileAccess: hostFileAccess, intent: intent)
        default:
            return [
                TaskDeliverableCheck(
                    id: "artifact.probe",
                    title: "Artifact probe",
                    status: .warning,
                    summary: "ASTRA found this artifact but does not have a deterministic probe for .\(ext.isEmpty ? "file" : ext) files yet.",
                    path: file.path
                )
            ]
        }
    }

    private static func artifactRoot(
        for file: TaskOutputDiscoveredFile,
        allowedRoots: [String]
    ) -> URL? {
        let fileURL = URL(fileURLWithPath: file.path)
        let standardizedPath = fileURL.standardizedFileURL.path
        let resolvedPath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path

        for root in allowedRoots {
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            let standardRoot = rootURL.standardizedFileURL.path
            let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard (standardizedPath == standardRoot || standardizedPath.hasPrefix(standardRoot + "/")),
                  (resolvedPath == resolvedRoot || resolvedPath.hasPrefix(resolvedRoot + "/")) else {
                continue
            }
            return rootURL
        }
        return nil
    }

    private static func requiredFileChecks(
        requiredFilenames: Set<String>,
        discoveredFilenames: Set<String>
    ) -> [TaskDeliverableCheck] {
        guard !requiredFilenames.isEmpty else { return [] }

        let missing = requiredFilenames.subtracting(discoveredFilenames).sorted()
        return [
            TaskDeliverableCheck(
                id: "artifact.required_files",
                title: "Required deliverable files",
                status: missing.isEmpty ? .passed : .failed,
                summary: missing.isEmpty
                    ? "All explicitly requested deliverable files were found."
                    : "Missing explicitly requested deliverable file\(missing.count == 1 ? "" : "s"): \(missing.joined(separator: ", ")).",
                path: nil
            )
        ]
    }

    private static func htmlChecks(
        _ file: TaskOutputDiscoveredFile,
        environment: TaskDeliverableVerificationEnvironment,
        hostFileAccess: HostFileAccessBroker,
        intent: HostFileAccessIntent
    ) async -> [TaskDeliverableCheck] {
        guard let html = try? hostFileAccess.readString(
            at: URL(fileURLWithPath: file.path),
            encoding: .utf8,
            intent: intent
        ) else {
            return [unreadableCheck(path: file.path)]
        }

        var checks: [TaskDeliverableCheck] = []
        let lower = html.lowercased()
        let hasHTMLShell = lower.contains("<html") || lower.contains("<!doctype html")
        checks.append(TaskDeliverableCheck(
            id: "html.structure",
            title: "HTML structure",
            status: hasHTMLShell ? .passed : .warning,
            summary: hasHTMLShell
                ? "HTML artifact includes a document shell."
                : "HTML artifact is readable, but no <html> or <!doctype html> shell was found.",
            path: file.path
        ))

        let scripts = inlineScripts(in: html)
        let externalScriptCount = externalScriptReferences(in: html)
        if scripts.isEmpty {
            checks.append(TaskDeliverableCheck(
                id: "javascript.syntax.inline",
                title: "Inline JavaScript syntax",
                status: externalScriptCount > 0 ? .warning : .skipped,
                summary: externalScriptCount > 0
                    ? "HTML uses external scripts; ASTRA did not fetch or execute external resources."
                    : "No inline JavaScript was found to syntax-check.",
                path: file.path
            ))
            return checks
        }

        for (index, script) in scripts.enumerated() {
            let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                checks.append(TaskDeliverableCheck(
                    id: "javascript.syntax.inline.\(index + 1)",
                    title: "Inline JavaScript syntax",
                    status: .skipped,
                    summary: "Inline script \(index + 1) is empty.",
                    path: file.path
                ))
                continue
            }
            checks.append(await syntaxCheck(
                source: trimmed,
                sourceLabel: "\(file.relativePath) inline script \(index + 1)",
                path: file.path,
                id: "javascript.syntax.inline.\(index + 1)",
                environment: environment
            ))
        }
        return checks
    }

    private static func javascriptChecks(
        _ file: TaskOutputDiscoveredFile,
        environment: TaskDeliverableVerificationEnvironment,
        hostFileAccess: HostFileAccessBroker,
        intent: HostFileAccessIntent
    ) async -> [TaskDeliverableCheck] {
        guard let source = try? hostFileAccess.readString(
            at: URL(fileURLWithPath: file.path),
            encoding: .utf8,
            intent: intent
        ) else {
            return [unreadableCheck(path: file.path)]
        }
        return [
            await syntaxCheck(
                source: source,
                sourceLabel: file.relativePath,
                path: file.path,
                id: "javascript.syntax.file",
                environment: environment
            )
        ]
    }

    private static func syntaxCheck(
        source: String,
        sourceLabel: String,
        path: String,
        id: String,
        environment: TaskDeliverableVerificationEnvironment
    ) async -> TaskDeliverableCheck {
        switch await environment.checkJavaScriptSyntax(source, sourceLabel) {
        case .passed:
            return TaskDeliverableCheck(
                id: id,
                title: "JavaScript syntax",
                status: .passed,
                summary: "JavaScript syntax check passed.",
                path: path
            )
        case .failed(let detail):
            return TaskDeliverableCheck(
                id: id,
                title: "JavaScript syntax",
                status: .failed,
                summary: detail,
                path: path
            )
        case .unavailable(let detail):
            return TaskDeliverableCheck(
                id: id,
                title: "JavaScript syntax",
                status: .warning,
                summary: detail,
                path: path
            )
        }
    }

    private static func jsonChecks(
        _ file: TaskOutputDiscoveredFile,
        hostFileAccess: HostFileAccessBroker,
        intent: HostFileAccessIntent
    ) -> [TaskDeliverableCheck] {
        guard let data = try? hostFileAccess.readData(
            at: URL(fileURLWithPath: file.path),
            intent: intent
        ) else {
            return [unreadableCheck(path: file.path)]
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            return [
                TaskDeliverableCheck(
                    id: "json.syntax",
                    title: "JSON syntax",
                    status: .passed,
                    summary: "JSON parsed successfully.",
                    path: file.path
                )
            ]
        } catch {
            return [
                TaskDeliverableCheck(
                    id: "json.syntax",
                    title: "JSON syntax",
                    status: .failed,
                    summary: "JSON did not parse: \(error.localizedDescription)",
                    path: file.path
                )
            ]
        }
    }

    private static func readableTextChecks(
        _ file: TaskOutputDiscoveredFile,
        hostFileAccess: HostFileAccessBroker,
        intent: HostFileAccessIntent
    ) -> [TaskDeliverableCheck] {
        guard (try? hostFileAccess.readString(
            at: URL(fileURLWithPath: file.path),
            encoding: .utf8,
            intent: intent
        )) != nil else {
            return [unreadableCheck(path: file.path)]
        }
        return [
            TaskDeliverableCheck(
                id: "text.readable",
                title: "Text readability",
                status: .passed,
                summary: "Artifact is readable UTF-8 text.",
                path: file.path
            )
        ]
    }

    private static func unreadableCheck(path: String) -> TaskDeliverableCheck {
        TaskDeliverableCheck(
            id: "artifact.readable",
            title: "Artifact readability",
            status: .failed,
            summary: "Artifact could not be read as expected.",
            path: path
        )
    }

    private static func summary(
        for level: TaskDeliverableQualityLevel,
        fileCount: Int,
        checks: [TaskDeliverableCheck]
    ) -> String {
        let failed = checks.filter { $0.status == .failed }.count
        let warnings = checks.filter { $0.status == .warning || $0.status == .skipped }.count
        switch level {
        case .failed:
            return "Deliverable verification failed: \(failed) deterministic check\(failed == 1 ? "" : "s") failed."
        case .syntaxVerified:
            return warnings == 0
                ? "Deliverable syntax verified for \(fileCount) artifact\(fileCount == 1 ? "" : "s")."
                : "Deliverable syntax verified with \(warnings) review warning\(warnings == 1 ? "" : "s")."
        case .needsHumanReview:
            return "Deliverable artifact exists, but ASTRA needs human review because deterministic probes were incomplete."
        case .artifactOnly:
            return "Deliverable artifact exists, but no automated quality proof was recorded."
        case .noArtifact:
            return "No deliverable artifact was found."
        case .notApplicable:
            return "No standalone deliverable was required."
        case .runtimeVerified:
            return "Deliverable runtime behavior was verified."
        case .behaviorVerified:
            return "Deliverable behavior was verified."
        }
    }

    private static func fileSize(_ path: String) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return nil
        }
        return size.uint64Value
    }

    private static func inlineScripts(in html: String) -> [String] {
        var scripts: [String] = []
        var searchStart = html.startIndex
        while let openRange = html.range(
            of: "<script",
            options: [.caseInsensitive],
            range: searchStart..<html.endIndex
        ) {
            guard let tagEnd = html.range(of: ">", range: openRange.upperBound..<html.endIndex) else {
                break
            }
            let openingTag = html[openRange.lowerBound..<tagEnd.upperBound].lowercased()
            guard let closeRange = html.range(
                of: "</script",
                options: [.caseInsensitive],
                range: tagEnd.upperBound..<html.endIndex
            ) else {
                break
            }
            if !openingTag.contains("src=") {
                scripts.append(String(html[tagEnd.upperBound..<closeRange.lowerBound]))
            }
            searchStart = closeRange.upperBound
        }
        return scripts
    }

    private static func externalScriptReferences(in html: String) -> Int {
        var count = 0
        var searchStart = html.startIndex
        while let openRange = html.range(
            of: "<script",
            options: [.caseInsensitive],
            range: searchStart..<html.endIndex
        ) {
            guard let tagEnd = html.range(of: ">", range: openRange.upperBound..<html.endIndex) else {
                break
            }
            let openingTag = html[openRange.lowerBound..<tagEnd.upperBound].lowercased()
            if openingTag.contains("src=") {
                count += 1
            }
            searchStart = tagEnd.upperBound
        }
        return count
    }

    private static func bounded(_ text: String, maxCharacters: Int) -> String {
        let clean = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
        guard clean.count > maxCharacters else { return clean }
        return String(clean.prefix(maxCharacters)) + "..."
    }
}
