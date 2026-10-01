import Foundation

/// Decides which polled git activity is worth a log line.
///
/// The repository panel polls every 30 s: ten read-only git commands plus a
/// `gh pr list` every minute or so. Logged one DEBUG line per command, that was
/// about 1,250 lines an hour, even overnight with nobody at the machine, and it
/// pushed everything else out of the rotated log — a 5 MB file held under two
/// days, so a bundle could no longer show a failure from the day before.
/// Failures keep their own ERROR/WARNING lines and mutating commands are still
/// logged; only the unremarkable read is dropped.
enum GitPollingLogPolicy {
    /// True for the read-only queries the panel's status refresh issues. Matches
    /// whole argument shapes, not just the subcommand: `branch` alone can delete.
    static func isReadOnlyPollQuery(_ arguments: [String]) -> Bool {
        let args = arguments.filter { $0 != "--no-optional-locks" }
        guard let command = args.first else { return false }
        let rest = Array(args.dropFirst())
        switch command {
        case "status", "diff", "rev-list", "remote":
            return !rest.contains { $0 == "--delete" || $0 == "add" || $0 == "remove" || $0 == "set-url" }
        case "rev-parse":
            return true
        case "worktree":
            return rest.first == "list"
        case "branch":
            return rest.allSatisfy { ["--show-current", "--list"].contains($0) || $0.hasPrefix("--format") }
        default:
            return false
        }
    }

    /// Remembers the last pull-request lookup outcome per repository and branch,
    /// so a poll that finds the same thing as the last one stays quiet and a
    /// change (a PR opened, merged, or closed) is still logged.
    final class LookupOutcomes: @unchecked Sendable {
        private let lock = NSLock()
        private var last: [String: String] = [:]

        /// True when `outcome` differs from the previous one for `key`.
        func recordChanged(key: String, outcome: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if last[key] == outcome { return false }
            last[key] = outcome
            return true
        }
    }
}

#if canImport(AppKit)
import AppKit

/// Tracks whether the Mac is asleep, its display is asleep, or the screen is
/// locked, so background polling can stand down. The panel already pauses when
/// the rail hides or the app leaves the foreground; an unattended machine with
/// the app frontmost did neither, and polled all night.
///
/// Reasons are tracked separately because they overlap: a locked screen is
/// usually also a sleeping display, and the first unlock signal must not
/// resume polling while the other reason still holds.
@MainActor
final class GitPollingSuspension {
    enum Reason: Hashable { case systemSleep, displaySleep, screenLocked }

    private(set) var reasons: Set<Reason> = []
    var isSuspended: Bool { !reasons.isEmpty }
    /// Called when the last reason clears, so the panel can refresh once.
    var onResume: (() -> Void)?

    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init(observeSystem: Bool = true) {
        guard observeSystem else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observe(workspace, NSWorkspace.willSleepNotification, begin: .systemSleep)
        observe(workspace, NSWorkspace.didWakeNotification, end: .systemSleep)
        observe(workspace, NSWorkspace.screensDidSleepNotification, begin: .displaySleep)
        observe(workspace, NSWorkspace.screensDidWakeNotification, end: .displaySleep)
        observe(distributed, Notification.Name("com.apple.screenIsLocked"), begin: .screenLocked)
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), end: .screenLocked)
    }

    deinit {
        for observer in observers { observer.center.removeObserver(observer.token) }
    }

    func begin(_ reason: Reason) {
        reasons.insert(reason)
    }

    func end(_ reason: Reason) {
        guard reasons.remove(reason) != nil, reasons.isEmpty else { return }
        onResume?()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, begin reason: Reason) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.begin(reason) }
        }
        observers.append((center, token))
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, end reason: Reason) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end(reason) }
        }
        observers.append((center, token))
    }
}
#endif
