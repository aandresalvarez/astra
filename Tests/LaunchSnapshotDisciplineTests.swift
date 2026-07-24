import Foundation
import Testing

/// Launch snapshot discipline.
///
/// A queued request must execute under the configuration it was ADMITTED with,
/// not whatever the user edited while it waited. `AgentTaskLaunchSnapshot`
/// freezes that configuration and `TaskExecutionLaunchSnapshotApplicator`
/// hands the runtime an unmanaged `launchTask` carrying the frozen values.
///
/// Five separate review findings then had exactly one shape: post-admission
/// code read the LIVE `task` for a snapshot-owned field instead of the frozen
/// `launchTask` (budget classification, the validation-strategy switch, both
/// isolation-cleanup call sites, the applicator mutating the live model, the
/// nil-runtimeID fallback, `ValidationService.runTests`). Each was found by
/// hand, one review round at a time.
///
/// These tests turn that bug class into something checkable. Every
/// `task.<snapshot-owned field>` occurrence left in the post-admission
/// execution files must appear in an explicit allowlist with a classification
/// and a one-line reason, so a NEW live read fails here immediately instead of
/// waiting for review round four.
///
/// Deliberately NOT re-tested here: the end-to-end freeze behaviour
/// (build a snapshot, edit the live task, detach, assert the detached task kept
/// the admitted values). `TaskExecutionLaunchSnapshotApplicatorTests` already
/// owns that. What is added instead is the structural guard that the
/// snapshot-owned field SET stays consistent across the whole freeze chain, so
/// the allowlist below cannot silently go stale when a field is added.
@Suite("Launch snapshot discipline")
struct LaunchSnapshotDisciplineTests {
    // MARK: - Files

    private static let applicatorPath = "Astra/Services/Tasks/TaskExecutionLaunchSnapshotApplicator.swift"
    private static let snapshotPath = "Astra/Services/Runtime/AgentTaskLaunchSnapshot.swift"
    private static let requestPath = "Astra/Models/TaskTurnRequest.swift"
    private static let workerPath = "Astra/Services/Runtime/AgentRuntimeWorker.swift"
    private static let queuePath = "Astra/Services/Tasks/TaskQueue.swift"

    /// The fields `detachedTask` overwrites from the frozen snapshot. Reading
    /// any of these off the live `task` after admission is the bug shape this
    /// suite exists to catch. Kept in sync with production by
    /// `snapshotOwnedFieldSetMatchesTheFreezeChain` below.
    private static let snapshotOwnedFields: Set<String> = [
        "executionEnvironmentSnapshotJSON",
        "executionRootPath",
        "isolationStrategy",
        "maxTurns",
        "model",
        "runtimeExplicitlySelected",
        "runtimeID",
        "runtimePermissionGrantsJSON",
        "skillSnapshotsJSON",
        "teamInstructions",
        "teamSize",
        "templateHooksJSON",
        "testCommand",
        "tokenBudget",
        "useAgentTeam",
        "validationStrategy"
    ]

    // MARK: - Freeze chain

    @Test("Snapshot-owned field set is consistent across the whole freeze chain")
    func snapshotOwnedFieldSetMatchesTheFreezeChain() throws {
        let snapshotSource = try fileText(Self.snapshotPath)
        let applicatorSource = try fileText(Self.applicatorPath)
        let requestSource = try fileText(Self.requestPath)

        // 1. The snapshot value type carries exactly these fields (plus `id`,
        //    which detachedTask copies from the source task, not the snapshot).
        let snapshotProperties = try Set(
            capturedNames(in: snapshotSource, pattern: #"(?m)^    let ([A-Za-z_]\w*):"#)
        ).subtracting(["id"])
        #expect(
            snapshotProperties == Self.snapshotOwnedFields,
            "AgentTaskLaunchSnapshot gained or lost a field. Update snapshotOwnedFields and re-audit the allowlists below: \(symmetricDifference(snapshotProperties, Self.snapshotOwnedFields))"
        )

        // 2. detachedTask assigns every one of them from the snapshot.
        let applied = try Set(
            capturedNames(in: applicatorSource, pattern: #"task\.([A-Za-z_]\w*) = snapshot\.\1\b"#)
        )
        #expect(
            applied == Self.snapshotOwnedFields,
            "TaskExecutionLaunchSnapshotApplicator.detachedTask must assign every snapshot-owned field from the snapshot: \(symmetricDifference(applied, Self.snapshotOwnedFields))"
        )

        // 3. Every field is actually captured at admission time — otherwise the
        //    "frozen" value is whatever the live task happened to hold later.
        let capturedAtAdmission = try Set(
            capturedNames(in: requestSource, pattern: #"= task\.([A-Za-z_]\w*)"#)
        )
        #expect(
            Self.snapshotOwnedFields.subtracting(capturedAtAdmission).isEmpty,
            "TaskTurnRequest / TaskExecutionPolicySnapshotV1 must capture every snapshot-owned field at admission: \(Self.snapshotOwnedFields.subtracting(capturedAtAdmission).sorted())"
        )

        // 4. The direct AgentTaskLaunchSnapshot(task:) constructor agrees.
        let capturedByInit = try Set(
            capturedNames(in: snapshotSource, pattern: #"= task\.([A-Za-z_]\w*)"#)
        )
        #expect(
            Self.snapshotOwnedFields.subtracting(capturedByInit).isEmpty,
            "AgentTaskLaunchSnapshot(task:) must capture every snapshot-owned field: \(Self.snapshotOwnedFields.subtracting(capturedByInit).sorted())"
        )
    }

    // MARK: - Live reads

    /// Reads of a snapshot-owned field off the LIVE task in the post-admission
    /// execution files. Each entry is pinned by its normalized source line, so
    /// moving code is free but changing one of these lines forces a re-review.
    ///
    /// `benign` = provably not a stale-configuration risk.
    /// `KNOWN GAP` = genuinely reads live state that the launch froze; tracked,
    /// not blessed.
    private static let allowedLiveReads: [AllowedOccurrence] = [
        .init(
            file: Self.workerPath,
            symbol: "task.model",
            line: #"model: task.model,"#,
            count: 1,
            classification: .knownGap,
            reason: "KNOWN GAP (diagnostic): names the model in AgentRuntimeFailureDiagnostic.classify, so a failure can be reported against a model this run never launched with. Should be launchTask.model, as the taskStarted audit and the policy manifest already are."
        ),
        .init(
            file: Self.workerPath,
            symbol: "task.tokenBudget",
            line: #"payload: "\(reason) (\(task.tokensUsed)/\(task.tokenBudget)). \(outcome)", run: run)"#,
            count: 1,
            classification: .knownGap,
            reason: "KNOWN GAP (cosmetic): the budget-exceeded event prints a limit that is NOT the one enforced two lines above (enforcement uses effectiveTokenBudget(for: launchTask)). tokensUsed is correctly live."
        ),
        .init(
            file: Self.workerPath,
            symbol: "task.tokenBudget",
            line: #"defaultBudget: task.tokenBudget,"#,
            count: 1,
            classification: .knownGap,
            reason: "KNOWN GAP (behavioural): utilityRuntimeConfiguration is called post-admission with the live task (verifier contract check, AI self-check, title generation), so a budget edited mid-run changes this run's utility budget."
        ),
        .init(
            file: Self.workerPath,
            symbol: "task.model",
            line: #"let resolution = RuntimeModelAvailability.resolveModel(task.model, for: selectedRuntime)"#,
            count: 1,
            classification: .benign,
            reason: "benign: alignTaskModelWithSelectedRuntime's parameter is NAMED task but every call site passes launchTask, so this already reads the frozen value. Shadowed name, not a live read."
        ),
        .init(
            file: Self.workerPath,
            symbol: "task.runtimeID",
            // Extra `#` only because this line ends in a quote.
            line: ##"fields["task_runtime_id"] = task.runtimeID ?? "none""##,
            count: 1,
            classification: .benign,
            reason: "benign: audit logging only, and the same shadowed launchTask parameter as the read above."
        ),
        .init(
            file: Self.queuePath,
            symbol: "task.templateHooksJSON",
            line: #"hooksJSON: task.templateHooksJSON,"#,
            count: 2,
            classification: .knownGap,
            reason: "KNOWN GAP (behavioural): inject/restoreTemplateHooks bracket the launch in executeTask, but read the live task. templateHooksJSON is snapshot-owned and executionPolicy.launchSnapshot is already in scope at both call sites."
        ),
        .init(
            file: Self.queuePath,
            symbol: "task.templateHooksJSON",
            line: #"if backup != nil || (!task.templateHooksJSON.isEmpty && task.templateHooksJSON != "{}") {"#,
            count: 2,
            classification: .knownGap,
            reason: "KNOWN GAP (audit accuracy): decides whether the injection is reported, from the same live value as the injection itself."
        ),
        .init(
            file: Self.queuePath,
            symbol: "task.templateHooksJSON",
            line: #"} else if !task.templateHooksJSON.isEmpty, task.templateHooksJSON != "{}" {"#,
            count: 2,
            classification: .knownGap,
            reason: "KNOWN GAP (behavioural): restore is graded against a value the user may have edited after the hooks were injected, so injected and restored state can disagree."
        )
    ]

    @Test("Post-admission live-task reads of snapshot-owned fields match the allowlist")
    func postAdmissionLiveTaskReadsMatchTheAllowlist() throws {
        var found: [SourceOccurrence: Int] = [:]
        for path in [Self.workerPath, Self.queuePath] {
            for (occurrence, count) in try occurrences(receiver: "task", in: path, assignments: false) {
                found[occurrence, default: 0] += count
            }
        }

        assertMatches(found: found, allowed: Self.allowedLiveReads, subject: "live-task read")
    }

    // MARK: - Frozen-copy mutations

    /// The inverse hazard: writes that land on the unmanaged `launchTask` never
    /// reach the durable task.
    private static let allowedFrozenMutations: [AllowedOccurrence] = [
        .init(
            file: Self.workerPath,
            symbol: "launchTask.executionEnvironmentSnapshotJSON",
            line: #"launchTask.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot("#,
            count: 1,
            classification: .benign,
            reason: "benign: settles the frozen copy's fallback environment for AgentRuntimeRunEnvironmentContext.prepare(task: launchTask), which then overwrites run.executionEnvironmentSnapshotJSON. Leaving the durable task alone is the point."
        )
    ]

    @Test("Mutations of the frozen launch copy match the allowlist")
    func frozenLaunchTaskMutationsMatchTheAllowlist() throws {
        var found: [SourceOccurrence: Int] = [:]
        for path in [Self.workerPath, Self.queuePath] {
            for (occurrence, count) in try occurrences(receiver: "launchTask", in: path, assignments: true) {
                found[occurrence, default: 0] += count
            }
        }

        assertMatches(found: found, allowed: Self.allowedFrozenMutations, subject: "frozen-copy mutation")
    }

    // MARK: - Allowlist model

    private enum Classification: String {
        case benign = "benign"
        case knownGap = "KNOWN GAP"
    }

    private struct SourceOccurrence: Hashable, CustomStringConvertible {
        let file: String
        let symbol: String
        let line: String

        var description: String { "\(file): \(symbol) -> \(line)" }
    }

    private struct AllowedOccurrence {
        let file: String
        let symbol: String
        let line: String
        let count: Int
        let classification: Classification
        let reason: String

        var occurrence: SourceOccurrence {
            SourceOccurrence(file: file, symbol: symbol, line: line)
        }
    }

    private func assertMatches(
        found: [SourceOccurrence: Int],
        allowed: [AllowedOccurrence],
        subject: String
    ) {
        #expect(
            allowed.allSatisfy { !$0.reason.isEmpty },
            "Every \(subject) allowlist entry needs a one-line reason saying why it is benign or what the gap is."
        )

        let expected = Dictionary(allowed.map { ($0.occurrence, $0.count) }, uniquingKeysWith: +)
        let tally = Dictionary(grouping: allowed, by: \.classification)
            .map { "\($0.value.count) \($0.key.rawValue)" }
            .sorted()
            .joined(separator: ", ")
        let unexpected = found.keys.filter { expected[$0] == nil }.map(\.description).sorted()
        #expect(
            unexpected.isEmpty,
            "New \(subject)(s) of a snapshot-owned field. Post-admission code must use the frozen launchTask; if an occurrence really is safe, add it to the allowlist with a reason (currently \(tally)): \(unexpected)"
        )

        let stale = expected.keys.filter { found[$0] == nil }.map(\.description).sorted()
        #expect(
            stale.isEmpty,
            "Allowlisted \(subject)(s) no longer exist — delete the entries so the remaining gaps stay honest: \(stale)"
        )

        let miscounted = expected.compactMap { occurrence, count -> String? in
            guard let actual = found[occurrence], actual != count else { return nil }
            return "\(occurrence) (allowlisted \(count), found \(actual))"
        }.sorted()
        #expect(
            miscounted.isEmpty,
            "Allowlisted \(subject) counts drifted — a duplicated line is a new occurrence and needs its own review: \(miscounted)"
        )
    }

    // MARK: - Source scanning

    /// Counts `<receiver>.<snapshot-owned field>` occurrences, keyed by the
    /// normalized source line rather than a line number so unrelated edits
    /// above them do not churn the allowlist.
    ///
    /// The scan covers the whole file rather than trying to compute the exact
    /// post-admission region: that only over-reports, and the allowlist absorbs
    /// the difference with a documented reason per entry.
    private func occurrences(
        receiver: String,
        in relativePath: String,
        assignments: Bool
    ) throws -> [SourceOccurrence: Int] {
        // Longest-first alternation, a leading negative lookbehind so
        // `launchTask.model` never matches a `task.` scan, and a trailing word
        // boundary so `task.tokensUsed` never matches `task.tokenBudget`.
        let alternation = Self.snapshotOwnedFields
            .sorted { ($0.count, $0) > ($1.count, $1) }
            .joined(separator: "|")
        let regex = try NSRegularExpression(
            pattern: "(?<![A-Za-z0-9_.])\(receiver)\\.(\(alternation))\\b"
        )

        var counts: [SourceOccurrence: Int] = [:]
        for rawLine in try fileText(relativePath).components(separatedBy: .newlines) {
            let code = Self.strippingLineComment(rawLine)
            let range = NSRange(code.startIndex..<code.endIndex, in: code)
            for match in regex.matches(in: code, range: range) {
                guard let fieldRange = Range(match.range(at: 1), in: code),
                      let matchRange = Range(match.range, in: code) else { continue }
                let remainder = code[matchRange.upperBound...].drop { $0 == " " || $0 == "\t" }
                guard Self.isAssignment(String(remainder)) == assignments else { continue }
                let occurrence = SourceOccurrence(
                    file: relativePath,
                    symbol: "\(receiver).\(code[fieldRange])",
                    line: Self.normalized(code)
                )
                counts[occurrence, default: 0] += 1
            }
        }
        return counts
    }

    /// True for `=`, `+=`, `<<=` and friends, false for `==`, `!=`, `>=`, `<=`.
    /// Writes are a different question from the stale reads this suite hunts.
    private static func isAssignment(_ remainder: String) -> Bool {
        remainder.range(of: "^(?:[-+*/%&|^]|<<|>>)?=(?!=)", options: .regularExpression) != nil
    }

    /// Drops a trailing `//` comment without touching `//` inside a string
    /// literal, so prose mentioning `task.model` never counts as a read while
    /// `"\(task.tokenBudget)"` inside an interpolated payload still does.
    private static func strippingLineComment(_ line: String) -> String {
        var result = ""
        var insideString = false
        var escaped = false
        var previous: Character?
        for character in line {
            if escaped {
                escaped = false
            } else if character == "\\", insideString {
                escaped = true
            } else if character == "\"" {
                insideString.toggle()
            } else if character == "/", previous == "/", !insideString {
                result.removeLast()
                return result
            }
            result.append(character)
            previous = character
        }
        return result
    }

    private static func normalized(_ line: String) -> String {
        line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func capturedNames(in text: String, pattern: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let captured = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captured])
        }
    }

    private func symmetricDifference(_ lhs: Set<String>, _ rhs: Set<String>) -> [String] {
        lhs.symmetricDifference(rhs).sorted()
    }

    private func fileText(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repositoryRoot().appending(path: relativePath), encoding: .utf8)
    }

    /// This file lives in <root>/Tests, so two levels up is the repository root
    /// regardless of the working directory a runner happens to use. Falls back
    /// to the shared marker-file walk if the build ever relocates sources.
    private static func repositoryRoot() -> URL {
        let derived = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: derived.appending(path: "Astra").path) {
            return derived
        }
        return (try? TestRepositoryRoot.resolve()) ?? derived
    }
}
