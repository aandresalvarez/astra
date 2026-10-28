import Foundation

/// One decision owner per process attempt. The process watchdog calls tick;
/// investigation never occupies the task queue or blocks the watchdog thread.
final class RuntimeSupervisionSession: @unchecked Sendable {
    struct Configuration: Sendable {
        var investigationSeconds: TimeInterval = 75
        var recheckSeconds: TimeInterval = 120
        var maximumInvestigations = 2
        var tokenReservation = 16_384
    }
    enum Decision: Equatable {
        case keepRunning
        case stop(reason: String, message: String)
    }
    typealias Investigator = @Sendable (RuntimeSupervisionEvidence) async -> RuntimeSupervisionAssessment

    let attemptID = UUID()
    private let lock = NSLock()
    private let configuration: Configuration
    private let goal: String
    private let runtime: String
    private let remoteCoverage: String
    private var baseline: RuntimeSupervisionFiles
    private let collectFiles: @Sendable () async -> RuntimeSupervisionFiles
    private let investigate: Investigator
    private let reserveTokens: @Sendable (Int) -> Bool
    private let report: @Sendable (RuntimeSupervisionReport) -> Void
    private var pending: Task<Void, Never>?
    private var generation = 0
    private var sequence = 0
    private var investigations = 0
    private var reservedTokens = 0
    private var latestRevision: Int?
    private var deadline: TimeInterval?
    private var nextCheck: TimeInterval = 0
    private var finished = false
    private var decision = Decision.keepRunning
    private var stopEvidence: (RuntimeSupervisionAssessment, RuntimeSupervisionEvidence)?
    private var stopPublished = false
    private var completedInvestigationRevision: Int?
    private let now: @Sendable () -> TimeInterval
    var tokenReservation: Int { lock.lock(); defer { lock.unlock() }; return reservedTokens }

    /// Investigation informs the status; OS ownership authorizes resuming an
    /// existing suspended child. Unknown remote work blocks replacement, not
    /// continuation of that same process. New progress invalidates this cue.
    func hasCompletedInvestigation(at revision: Int) -> Bool {
        lock.withLock { !finished && pending == nil && completedInvestigationRevision == revision }
    }

    init(goal: String, runtime: String, remoteCoverage: String, baseline: RuntimeSupervisionFiles,
         configuration: Configuration = .init(),
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         collectFiles: @escaping @Sendable () async -> RuntimeSupervisionFiles,
         investigate: @escaping Investigator, reserveTokens: @escaping @Sendable (Int) -> Bool,
         report: @escaping @Sendable (RuntimeSupervisionReport) -> Void) {
        self.goal = String(goal.prefix(600)); self.runtime = runtime
        self.remoteCoverage = remoteCoverage; self.baseline = baseline
        self.configuration = configuration; self.now = now
        self.collectFiles = collectFiles; self.investigate = investigate
        self.reserveTokens = reserveTokens; self.report = report
    }

    func tick(_ observation: RuntimeSupervisionObservation, investigationDue: Bool) -> Decision {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return .keepRunning }
        let time = now()
        if let revision = latestRevision, revision != observation.progressRevision {
            let wasChecking = pending != nil || nextCheck > 0 || decision != .keepRunning
            generation += 1; pending?.cancel(); pending = nil; deadline = nil
            decision = .keepRunning; nextCheck = 0
            investigations = 0
            stopEvidence = nil
            stopPublished = false
            completedInvestigationRevision = nil
            if wasChecking { emit(.resumed, "The provider is producing new progress. ASTRA dismissed the earlier stall check.") }
        }
        latestRevision = observation.progressRevision
        if let deadline, time >= deadline {
            generation += 1; pending?.cancel(); pending = nil; self.deadline = nil
            return stop("The independent progress check exceeded its time limit. ASTRA could not verify continued progress and is stopping this attempt.", reason: "provider_supervision_inconclusive")
        }
        if case .stop = decision { return decision }
        guard pending == nil, investigationDue, time >= nextCheck else { return .keepRunning }
        guard investigations < configuration.maximumInvestigations else {
            return stop("The task stayed quiet after its bounded progress checks. Partial work is preserved; review it before resuming.", reason: "provider_supervision_inconclusive")
        }
        investigations += 1
        guard configuration.tokenReservation == 0 || reserveTokens(configuration.tokenReservation) else {
            return stop("There is not enough remaining token budget for an independent progress check. Partial work is preserved.", reason: "provider_supervision_budget_unavailable")
        }
        reservedTokens += configuration.tokenReservation
        generation += 1
        let current = generation
        let previousFiles = baseline
        deadline = time + configuration.investigationSeconds
        emit(.checking, "No meaningful provider progress for \(observation.quietSeconds) seconds. ASTRA is checking task files, runtime activity and known waits with an independent model.")
        pending = Task { [weak self] in
            guard let self else { return }
            let files = await collectFiles()
            guard !Task.isCancelled else { return }
            let changes = files.recentChanges(since: previousFiles, quietSeconds: observation.quietSeconds).prefix(20).map { path in
                let before = previousFiles.metadata[path]?.split(separator: "|") ?? []
                let after = files.metadata[path]?.split(separator: "|") ?? []
                let changed = after.prefix(2).compactMap { Double($0) }.max() ?? 0
                return RuntimeSupervisionEvidence.FileDelta(path: String(path.prefix(300)),
                    previousBytes: before.count > 2 ? Int64(before[2]) : nil,
                    currentBytes: after.count > 2 ? Int64(after[2]) : nil,
                    changedSecondsAgo: max(0, Int(Date().timeIntervalSince1970 - changed)))
            }
            var evidence = RuntimeSupervisionEvidence(
                goal: goal, runtime: runtime, observation: observation,
                changedFiles: changes,
                fileCoverage: ([files.unavailable, previousFiles.unavailable].compactMap { $0 }
                    + files.coverageNotes + ["Up to 20 metadata changes during the quiet interval; changes are not attributed to a specific writer."]).joined(separator: " "),
                remoteCoverage: remoteCoverage)
            var assessment = await investigate(evidence)
            guard !Task.isCancelled else { return }
            var finalFiles = files
            if assessment.assessment == .suspectedStalled {
                // A model may take tens of seconds. Revalidate the metadata it
                // saw before accepting a negative verdict about a silent writer.
                finalFiles = await collectFiles()
                guard !Task.isCancelled else { return }
                let changedPaths = finalFiles.changes(since: files)
                evidence.postAssessmentFileChanges = changedPaths.prefix(20).map { String($0.prefix(300)) }
                evidence.postAssessmentFileCoverage = ([finalFiles.unavailable].compactMap { $0 } + finalFiles.coverageNotes).joined(separator: " ")
                if !changedPaths.isEmpty {
                    assessment = .inconclusive("Files changed during the independent assessment. Its earlier stall verdict is no longer current; useful progress remains unverified.")
                } else if finalFiles.unavailable != nil || finalFiles.unavailable != files.unavailable
                            || finalFiles.coverageNotes != files.coverageNotes {
                    assessment = .inconclusive("File coverage changed during the independent assessment. The earlier stall verdict could not be revalidated.")
                }
            }
            complete(assessment, evidence: evidence, files: finalFiles, generation: current)
        }
        return .keepRunning
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        finished = true; generation += 1; pending?.cancel(); pending = nil
    }

    /// The monitor calls this only after atomically rechecking the progress
    /// revision and claiming the stop. A late verdict alone cannot publish it.
    func confirmStop() {
        lock.lock(); defer { lock.unlock() }
        guard !finished, !stopPublished, case .stop(_, let message) = decision else { return }
        stopPublished = true
        emit(.stopping, message, assessment: stopEvidence?.0, evidence: stopEvidence?.1)
        stopEvidence = nil
    }

    private func complete(_ assessment: RuntimeSupervisionAssessment, evidence: RuntimeSupervisionEvidence,
                          files: RuntimeSupervisionFiles, generation: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, self.generation == generation, !Task.isCancelled else { return }
        guard let deadline, now() < deadline else {
            pending = nil; self.deadline = nil
            decision = .stop(reason: "provider_supervision_inconclusive", message: "The independent progress check returned after its deadline. Progress remains unverified.")
            stopEvidence = (.inconclusive("Investigation deadline expired."), evidence)
            return
        }
        pending = nil; self.deadline = nil
        baseline = files
        completedInvestigationRevision = evidence.observation.progressRevision
        var assessment = assessment
        if (assessment.assessment == .progressing && (!evidence.supportsProgress || !assessment.evidenceIDs.contains("files")))
            || (assessment.assessment == .waiting && (!evidence.supportsWaiting || !assessment.evidenceIDs.contains("runtime"))) {
            assessment = .inconclusive("The model's conclusion was not supported by the available observations.")
        }
        let followUp = investigations < configuration.maximumInvestigations
            ? "ASTRA will check again in \(Int(configuration.recheckSeconds)) seconds if the provider stays quiet."
            : "ASTRA will allow \(Int(configuration.recheckSeconds)) more seconds for new provider progress before stopping this attempt."
        switch assessment.assessment {
        case .progressing, .waiting:
            nextCheck = now() + configuration.recheckSeconds
            emit(assessment.assessment == .progressing ? .progressing : .waiting,
                 "Independent model assessment: \(assessment.explanation) \(followUp)", assessment: assessment, evidence: evidence)
        case .inconclusive:
            nextCheck = now() + configuration.recheckSeconds
            emit(.inconclusive, "Progress is unverified: \(assessment.explanation) \(followUp)", assessment: assessment, evidence: evidence)
        case .suspectedStalled:
            decision = .stop(reason: "provider_supervisor_stalled", message: "The independent check found a likely stall: \(assessment.explanation) ASTRA is stopping this attempt; partial work is preserved.")
            stopEvidence = (assessment, evidence)
        }
    }

    private func stop(_ message: String, reason: String) -> Decision {
        decision = .stop(reason: reason, message: message)
        return decision
    }

    private func emit(_ phase: RuntimeSupervisionReport.Phase, _ message: String,
                      assessment: RuntimeSupervisionAssessment? = nil, evidence: RuntimeSupervisionEvidence? = nil) {
        sequence += 1
        report(.init(attemptID: attemptID, sequence: sequence, phase: phase, message: message,
                     assessment: assessment, evidence: evidence, reservedTokens: reservedTokens))
    }
}
