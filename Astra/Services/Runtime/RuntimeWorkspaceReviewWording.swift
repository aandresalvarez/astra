import Foundation
import ASTRAModels

/// What a person reads in "Review workspace". Each sentence names the task,
/// the folder and the one fact that holds it, and says what a button does.
/// The words ASTRA uses for its own bookkeeping stay out of it.
///
/// Design: docs/specs/2026-11-18-workspace-reservation-and-parallelism.md, Wording.
@MainActor
enum RuntimeWorkspaceReviewWording {
    struct Dialog: Equatable {
        let title: String
        let message: String
        /// False while a holder is itself still at work: no "Start now".
        let canStart: Bool
    }

    /// How an SSH job is named to a person, by job ID.
    struct SSHJob: Equatable {
        var label: String?
        var host: String
    }

    /// Folder names for a set of claims, each once. A repository's Git data
    /// is not named next to the repository it belongs to.
    nonisolated static func folders(_ claims: [TaskResourceLockClaim]) -> [String] {
        var names: [String] = []
        func add(_ name: String) { if !name.isEmpty, !names.contains(name) { names.append(name) } }
        for claim in claims where claim.resourceKind == .workspace {
            add(URL(fileURLWithPath: claim.resourceKey).lastPathComponent)
        }
        for claim in claims where claim.resourceKind == .gitCommonDirectory {
            var url = URL(fileURLWithPath: claim.resourceKey)
            if url.lastPathComponent == ".git" { url.deleteLastPathComponent() }
            add(url.lastPathComponent)
        }
        return names
    }

    nonisolated private static func list(_ items: [String]) -> String {
        guard items.count > 2 else { return items.joined(separator: " and ") }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    nonisolated private static func code(_ names: [String]) -> String { list(names.map { "`\($0)`" }) }

    /// Docker Desktop alone leaves nine. The record keeps every one of them.
    nonisolated static let namedProcessLimit = 6

    /// The line left in a holder's history after a person started past it.
    /// Nothing asks about that run again afterwards, so its Retry does not
    /// come back; the task itself continues with a new message.
    nonisolated static func holderNote(folders: [String], on date: Date = Date()) -> String {
        let day = date.formatted(.dateTime.month(.abbreviated).day())
        let place = folders.isEmpty ? "its folders" : code(folders)
        return "You let other tasks use \(place) on \(day), before ASTRA could confirm that this run's work had ended. "
            + "Retry is not available for that run. Send a new message here to continue."
    }

    static func dialog(_ review: RuntimeWorkspaceReview.Review, jobs: [String: SSHJob] = [:]) -> Dialog {
        let wanted = folders(review.holders.flatMap(\.claims))
        let place = wanted.isEmpty ? "this workspace" : code(wanted)
        let active = review.holders.filter(\.isActive)
        guard active.isEmpty else {
            let lines = active.map { holder -> String in
                let name = "\"\(holder.title)\""
                if holder.blockers.contains(.taskWorking) { return "\(name) is still working." }
                if case .providerAlive(let pid)? = holder.blockers.first(where: { if case .providerAlive = $0 { true } else { false } }) {
                    return "The provider that \(name) started (process \(pid)) is still running."
                }
                return "ASTRA is still closing the last run of \(name)."
            }
            return Dialog(title: "Something is still running in \(place)",
                message: lines.joined(separator: " ") + " This request starts when that ends. Open the task to see it or stop it.",
                canStart: false)
        }
        var paragraphs: [String] = []
        for holder in review.holders {
            let name = "\"\(holder.title)\""
            var sentences: [String] = []
            // Every process the holder left behind, in one sentence, whichever
            // of its runs started it. A long list names the first few.
            let left = holder.blockers.flatMap { blocker -> [RuntimeLocalSurvivorObservation.Survivor] in
                if case .survivors(let found) = blocker { found } else { [] }
            }
            if !left.isEmpty {
                var named = left.prefix(namedProcessLimit).map { "`\($0.name)` (process \($0.process.pid))" }
                if left.count > namedProcessLimit { named.append("\(left.count - namedProcessLimit) more") }
                let one = left.count == 1
                sentences.append("\(name) has ended, but \(list(named)), which it started, \(one ? "is" : "are") still running. "
                    + "Starting now does not stop \(one ? "it" : "them"), and \(one ? "it" : "they") can still change files there.")
            }
            for blocker in holder.blockers {
                switch blocker {
                case .survivors:
                    break
                case .sshJobs(let ids):
                    let named = ids.map { id -> String in
                        guard let job = jobs[id] else { return "\(id.prefix(8))" }
                        return (job.label.map { "\"\($0)\"" } ?? "\(id.prefix(8))") + " on `\(job.host)`"
                    }
                    let one = ids.count == 1
                    sentences.append("\(name) has \(one ? "an SSH job that has" : "SSH jobs that have") not ended: \(list(named)). "
                        + "Starting now does not stop \(one ? "it" : "them").")
                case .sshJobsUnreadable:
                    sentences.append("ASTRA cannot read the SSH job records of \(name), so it cannot tell whether one is still running.")
                case .container:
                    sentences.append("\(name) ran in a container that ASTRA cannot look inside.")
                case .placementUnrecorded:
                    sentences.append("ASTRA has no record of where the last run of \(name) ran.")
                case .lostRun:
                    sentences.append("ASTRA lost track of a run of \(name) and cannot confirm its commands ended. Restarting the Mac also settles this.")
                case .processTableUnreadable:
                    sentences.append("ASTRA could not read the list of running processes, so it cannot tell whether \(name) left one behind.")
                case .settlementUnconfirmed:
                    sentences.append("ASTRA was interrupted while closing a run of \(name) and cannot confirm its commands ended.")
                case .sessionUnverified:
                    sentences.append("ASTRA cannot confirm that the provider session of \(name) ended.")
                case .lineageUnreadable:
                    sentences.append("ASTRA cannot read the earlier runs of \(name).")
                case .taskWorking, .providerAlive, .settling:
                    break
                }
            }
            let others = folders(holder.otherClaims).filter { !wanted.contains($0) }
            if !others.isEmpty { sentences.append("Starting now also frees \(code(others)), which \(name) was using.") }
            paragraphs.append(sentences.joined(separator: " "))
        }
        let holders = list(review.holders.map { "\"\($0.title)\"" })
        paragraphs.append("Starting now lets this request, and any later one, use \(place). "
            + "After that, Retry is not available in \(holders) for that run. A new message there still works.")
        return Dialog(title: "Start in \(place) now?", message: paragraphs.joined(separator: "\n\n"), canStart: true)
    }
}
