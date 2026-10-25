import Foundation
import Testing

/// A child process waited on from the main actor freezes the app for as long
/// as the child runs. The 2026-10-21 production profile of a send on a long
/// task spent ~1.6 s of it in `git status`, called synchronously from the
/// worker's pre-launch baseline: the helper was `nonisolated`, its caller was
/// `@MainActor`, and nothing in between said so.
///
/// The positive rule: a `Process` is created only behind an async boundary —
/// inside `BlockingWork.run`, `Task.detached` or a dispatch `async` closure,
/// or in an `async` function that is not main-actor isolated (which Swift
/// runs off the main actor). A synchronous launcher can be called from
/// anywhere, including the main actor, so it is not allowed by default.
///
/// The sites below predate the rule. The list only shrinks: a listed site
/// that now complies, or no longer exists, fails until it is removed here.
@Suite("Process launches stay off the main actor")
struct MainActorProcessLaunchFitnessTests {
    /// `file#function`, each with why it has not moved yet.
    static let grandfathered: [String: String] = [
        "Astra/Services/Browser/ControlledBrowserController.swift#ensureLaunched": "spawns the browser without waiting; main-actor controller",
        "Astra/Services/Browser/ControlledBrowserController.swift#runningDebugTargetSync": "called through a dispatch hop by its async wrapper",
        "Astra/Services/Diagnostics/LogDiagnosticsService.swift#createZipArchive": "diagnostics export",
        "Astra/Services/Feedback/FeedbackEvidenceBuilder.swift#createDeterministicArchive": "feedback export",
        "Astra/Services/Feedback/FeedbackManualExportService.swift#archiveEntries": "feedback export",
        "Astra/Services/Feedback/FeedbackManualExportService.swift#createArchive": "feedback export",
        "Astra/Services/Persistence/FeedbackEvidenceArchiveValidator.swift#runUnzip": "feedback export",
        "Astra/Services/Runtime/AntigravityCLIRuntime.swift#runProbe": "readiness probe",
        "Astra/Services/Runtime/CodexAppServerModelProbe.swift#conversation": "readiness probe",
        "Astra/Services/Runtime/CodexCLIRuntime.swift#probeVersion": "readiness probe",
        "Astra/Services/Runtime/CodexMCPListPolicyProbe.swift#run": "readiness probe",
        "Astra/Services/Runtime/CopilotCLIRuntime.swift#probeVersion": "readiness probe",
        "Astra/Services/Runtime/CursorCLIRuntime.swift#runProbe": "readiness probe",
        "Astra/Services/Runtime/IsolationService.swift#runGitSync": "isolation setup",
        "Astra/Services/Runtime/OpenCodeCLIRuntime.swift#isGitBackedDirectory": "readiness probe",
        "Astra/Services/Runtime/OpenCodeCLIRuntime.swift#runProbe": "readiness probe",
        "Astra/Services/Runtime/RuntimePathResolver.swift#probeLoginShellPATH": "login-shell PATH probe",
        "Astra/Services/Settings/ApplicationInstallationService.swift#schedule": "installer handoff at quit",
        "Astra/Services/Startup/StoreStartupBlockedView.swift#relaunch": "relaunch at a blocked startup",
        "Astra/Services/Tasks/TaskForkPolicyService.swift#runGit": "default runner, called from Task.detached"
    ]

    @Test("Every Process is created behind an async boundary, or is a listed holdover")
    func processLaunchesAreOffTheMainActor() throws {
        let sites = try processSites()
        let unlisted = sites.filter { !$0.compliant && Self.grandfathered[$0.key] == nil }
        #expect(unlisted.isEmpty, """
            New synchronous or main-actor Process launches: \(unlisted.map { "\($0.key) (line \($0.line))" }). \
            Wrap the launch in `BlockingWork.run { ... }`, or make the function async and not main-actor isolated.
            """)

        let stillHeld = Set(sites.filter { !$0.compliant }.map(\.key))
        let moved = Set(Self.grandfathered.keys).subtracting(stillHeld)
        #expect(moved.isEmpty, "These no longer launch synchronously; remove them from the list: \(moved.sorted())")
    }

    @Test("The classifier tells the boundaries apart")
    func classifierRecognizesBoundaries() {
        let source = """
        @MainActor
        enum Sample {
            static func blocking() -> Int {
                let process = Process()
                return 0
            }
            nonisolated static func offMain() async -> Int {
                let process = Process()
                return 0
            }
            static func wrapped() async -> Int {
                await BlockingWork.run {
                    let process = Process()
                    return 0
                }
            }
            func onMain() async {
                let process = Process()
            }
            func afterClosedBoundary() async {
                await BlockingWork.run {
                    return 1
                }
                let process = Process()
            }
        }
        """
        let sites = Self.classify(source, path: "Sample.swift")
        #expect(sites.map(\.function) == ["blocking", "offMain", "wrapped", "onMain", "afterClosedBoundary"])
        #expect(sites.map(\.compliant) == [false, true, true, false, false])
    }

    // MARK: - Classification

    struct Site {
        let path: String
        let function: String
        let line: Int
        let compliant: Bool
        var key: String { "\(path)#\(function)" }
    }

    private func processSites() throws -> [Site] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appRoot = root.appendingPathComponent("Astra")
        let enumerator = try #require(FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil))
        var sites: [Site] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("Process()") else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            sites += Self.classify(text, path: relative)
        }
        return sites
    }

    /// Indentation-scoped, which this codebase's formatting makes reliable:
    /// the enclosing function is the nearest less-indented `func`, its type
    /// the nearest less-indented type declaration.
    static func classify(_ text: String, path: String) -> [Site] {
        let lines = text.components(separatedBy: "\n")
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        var sites: [Site] = []
        for (index, line) in lines.enumerated() where line.contains("Process()") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { continue }
            let depth = indent(line)
            guard let functionLine = (0...index).reversed().first(where: {
                indent(lines[$0]) < depth && lines[$0].range(of: #"\bfunc\s+\w+"#, options: .regularExpression) != nil
            }) else { continue }
            let declaration = lines[functionLine]
            let name = declaration.range(of: #"func\s+(\w+)"#, options: .regularExpression)
                .map { String(declaration[$0].dropFirst(4)).trimmingCharacters(in: .whitespaces) } ?? "?"
            var signature = ""
            for candidate in lines[functionLine...] {
                signature += candidate
                if candidate.contains("{") { break }
            }
            let attributes = lines[max(0, functionLine - 3)...functionLine].joined(separator: "\n")
            let functionDepth = indent(declaration)
            let typeLine = (0..<functionLine).reversed().first {
                indent(lines[$0]) < functionDepth
                    && lines[$0].range(of: #"\b(class|struct|enum|actor|extension)\s"#, options: .regularExpression) != nil
            }
            let typeAttributes = typeLine.map { lines[max(0, $0 - 2)...$0].joined(separator: "\n") } ?? ""
            let isMainActor = attributes.contains("@MainActor")
                || (typeAttributes.contains("@MainActor") && !declaration.contains("nonisolated"))
            // A completed off-main closure earlier in the function does not
            // protect subsequent main-actor work. Match an enclosing scope,
            // not merely a boundary name somewhere in the preceding text.
            let insideBoundary = (functionLine..<index).contains { candidate in
                let boundaryDepth = indent(lines[candidate])
                guard boundaryDepth < depth,
                      lines[candidate].range(
                        of: #"BlockingWork\.run|Task\.detached|DispatchQueue[^\n]*\.async"#,
                        options: .regularExpression
                      ) != nil else { return false }
                return !lines[(candidate + 1)..<index].contains {
                    indent($0) <= boundaryDepth && $0.trimmingCharacters(in: .whitespaces).hasPrefix("}")
                }
            }
            let isAsync = signature.contains(" async")
            sites.append(Site(
                path: path,
                function: name,
                line: index + 1,
                compliant: insideBoundary || (isAsync && !isMainActor)
            ))
        }
        return sites
    }
}
