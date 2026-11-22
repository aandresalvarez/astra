import Darwin
import Foundation
import Observation
import SwiftData
import SwiftUI
import ASTRACore
import ASTRAModels

/// Finds out, before the main window is built, whether the workspace folders
/// can be read.
///
/// The main window's startup work reads those folders on the main actor:
/// recovery of interrupted work has to settle from one consistent read of the
/// store before anything can start. A read can wait on things ASTRA does not
/// control. A new build's first read inside a protected folder such as
/// Documents raises a macOS privacy prompt and blocks until it is answered,
/// and a volume that stopped responding blocks a read for as long as it
/// likes. On the main actor that wait is an app with no window that does not
/// respond.
///
/// So each folder is opened here first, on a queue of its own, while the
/// window says what it is waiting for. The main window is built only once
/// they have answered, which keeps the order its startup relies on: nothing
/// can be started before interrupted work is settled, because there is
/// nothing on screen to start it from.
///
/// A folder macOS refuses is said too, with the way to allow it, instead of
/// an app that opens and then fails at everything inside that folder.
///
/// Read-only and idempotent. It opens each folder and closes it, keeps
/// nothing, and decides nothing about the store.
@MainActor
@Observable
final class StartupFolderAccessGate {
    enum State: Equatable {
        /// Folders are being asked, or are about to be.
        case waiting
        /// macOS refused these folders. Nothing is waiting on them: a refusal
        /// answers at once, so going on from here cannot stall the app.
        case refused([String])
        case open
    }

    private(set) var state: State
    /// The folder being asked now, for the waiting view to name.
    private(set) var waitingOn: String?

    var isOpen: Bool { state == .open }

    @ObservationIgnored private var asking: Task<Void, Never>?
    @ObservationIgnored private var startedAt: UInt64?
    @ObservationIgnored private let isRefused: @Sendable (String) -> Bool

    /// - Parameter isRefused: Opens the folder, however long that takes, and
    ///   says whether macOS refused it.
    init(
        startsOpen: Bool = StartupFolderAccessGate.isSkipped(arguments: ProcessInfo.processInfo.arguments),
        isRefused: @escaping @Sendable (String) -> Bool = { StartupFolderAccessGate.isRefused($0) }
    ) {
        state = startsOpen ? .open : .waiting
        self.isRefused = isRefused
    }

    /// UI test launches seed their own data and wait on nothing, as the rest
    /// of the startup work skips them.
    nonisolated static func isSkipped(arguments: [String]) -> Bool {
        arguments.contains { $0.hasPrefix("--uitesting") }
    }

    /// The folders the main window's startup work reads: every stored
    /// workspace's. A store that cannot list them is not waited on.
    static func workspaceFolders(in context: ModelContext) -> [String] {
        ((try? context.fetch(FetchDescriptor<Workspace>())) ?? []).map(\.primaryPath)
    }

    /// Asks every folder, however long that takes, and opens the gate when
    /// none was refused. Every window awaits the same asking, and `folders`
    /// is evaluated once.
    func open(folders: () -> [String]) async {
        guard state == .waiting else { return }
        if let asking {
            await asking.value
            return
        }
        startedAt = DispatchTime.now().uptimeNanoseconds
        await ask(Self.unique(folders()))
    }

    /// Asks the refused folders again, after the person changed the setting.
    func tryAgain() async {
        guard case .refused(let folders) = state else { return }
        state = .waiting
        startedAt = DispatchTime.now().uptimeNanoseconds
        await ask(folders)
    }

    /// Opens the gate over refused folders. Their reads fail at once from
    /// here on, as they would have without the gate.
    func continueAnyway() {
        guard case .refused(let folders) = state else { return }
        state = .open
        log(outcome: "continued_refused", folderCount: folders.count)
    }

    private func ask(_ folders: [String]) async {
        let asking = Task { @MainActor in
            var refused: [String] = []
            for folder in folders {
                self.waitingOn = folder
                if await Self.answer(from: folder, isRefused: self.isRefused) { refused.append(folder) }
            }
            self.waitingOn = nil
            self.asking = nil
            self.state = refused.isEmpty ? .open : .refused(refused)
            self.log(outcome: refused.isEmpty ? "answered" : "refused", folderCount: folders.count)
        }
        self.asking = asking
        await asking.value
    }

    private func log(outcome: String, folderCount: Int) {
        PerformanceTelemetry.log(
            "startup_folder_access",
            durationMilliseconds: startedAt.map { PerformanceTelemetry.elapsedMilliseconds(since: $0) },
            level: .info,
            fields: ["outcome": outcome, "folder_count": String(folderCount)]
        )
    }

    nonisolated private static let queue = DispatchQueue(label: "com.coral.astra.startup-folder-access", qos: .userInitiated)

    /// Runs `isRefused` on a queue of its own, never the cooperative pool a
    /// blocked open would starve, and returns its answer when it has one.
    nonisolated private static func answer(
        from folder: String, isRefused: @escaping @Sendable (String) -> Bool
    ) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async { continuation.resume(returning: isRefused(folder)) }
        }
    }

    /// Opens the folder for reading and closes it. That is the access macOS
    /// asks permission for, and its cost does not grow with the folder.
    /// True only when macOS refused: a privacy refusal is `EPERM`. A folder
    /// that is missing, or that file permissions keep closed, is not
    /// something the privacy setting can change, so it is not reported here.
    nonisolated static func isRefused(_ folder: String) -> Bool {
        let descriptor = Darwin.open(folder, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor < 0 else {
            Darwin.close(descriptor)
            return false
        }
        return errno == EPERM
    }

    nonisolated private static func unique(_ folders: [String]) -> [String] {
        var seen = Set<String>()
        return folders.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Builds the main window's content only once the gate is open. Until then
/// it shows what is being waited for, or what macOS refused.
struct StartupFolderAccessRoot<Content: View>: View {
    let gate: StartupFolderAccessGate
    let folders: () -> [String]
    @ViewBuilder let content: () -> Content

    var body: some View {
        switch gate.state {
        case .open:
            content()
        case .waiting:
            StartupFolderAccessWaitingView(gate: gate)
                .task { await gate.open(folders: folders) }
        case .refused(let refused):
            StartupFolderAccessRefusedNotice(
                appName: AppChannel.current.displayName,
                folders: refused,
                openSettings: { _ = MacOSPermissionDiagnostics.openSettings(for: .filesAndFolders) },
                tryAgain: { Task { await gate.tryAgain() } },
                continueAnyway: { gate.continueAnyway() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Says nothing for a moment, since the folders normally answer at once.
/// After that it names the folder and what to do. There is no way past the
/// wait: the main window opens by itself as soon as the folder answers, and
/// opening it sooner would put the wait back on the main actor.
struct StartupFolderAccessWaitingView: View {
    static let quietSeconds: Double = 1

    let gate: StartupFolderAccessGate
    @State private var showsWait = false

    var body: some View {
        // A stack, not a Group: while it shows nothing it must still be a
        // view, or neither this task nor the one that opens the gate runs.
        ZStack {
            if showsWait, let folder = gate.waitingOn {
                StartupFolderAccessWaitingNotice(appName: AppChannel.current.displayName, folder: folder)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: .seconds(Self.quietSeconds))
            guard !Task.isCancelled else { return }
            showsWait = true
        }
    }
}

/// What the window says while a folder has not answered. ASTRA cannot tell a
/// pending macOS prompt from a disk that is slow, so it says both.
struct StartupFolderAccessWaitingNotice: View {
    let appName: String
    let folder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Allow \(appName) to read your workspaces", systemImage: "folder.badge.questionmark")
                .font(Stanford.heading(22))
                .foregroundStyle(Stanford.black)
            Text("macOS may be asking whether \(appName) can read this folder. Choose Allow in that dialog. \(appName) opens by itself as soon as the folder answers.")
                .font(Stanford.body(14))
                .foregroundStyle(Stanford.coolGrey)
                .fixedSize(horizontal: false, vertical: true)
            StartupFolderAccessPath(folder: folder)
            Text("If no dialog is showing, the folder may be on a disk or server that is not connected.")
                .font(Stanford.caption(12))
                .foregroundStyle(Stanford.coolGrey)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(maxWidth: 560, alignment: .leading)
    }
}

/// What the window says when macOS refused a workspace folder: why it
/// matters, where to allow it, and the three ways on.
struct StartupFolderAccessRefusedNotice: View {
    let appName: String
    let folders: [String]
    let openSettings: () -> Void
    let tryAgain: () -> Void
    let continueAnyway: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("\(appName) can't read your workspaces", systemImage: "folder.badge.gearshape")
                .font(Stanford.heading(22))
                .foregroundStyle(Stanford.black)
            Text("macOS is not letting \(appName) read \(Self.subject(folders.count)). Without it, the tasks and files in \(folders.count == 1 ? "that workspace" : "those workspaces") can't be opened or run.")
                .font(Stanford.body(14))
                .foregroundStyle(Stanford.coolGrey)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(folders.prefix(Self.listedFolders), id: \.self) { StartupFolderAccessPath(folder: $0) }
                if folders.count > Self.listedFolders {
                    Text("and \(folders.count - Self.listedFolders) more")
                        .font(Stanford.caption(12))
                        .foregroundStyle(Stanford.coolGrey)
                }
            }
            Text("Open System Settings > Privacy & Security > Files & Folders, turn on the folder for \(appName), then try again. If macOS asks you to quit and reopen \(appName), do that instead.")
                .font(Stanford.body(14))
                .foregroundStyle(Stanford.coolGrey)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Open Files & Folders", action: openSettings)
                    .buttonStyle(StanfordButtonStyle())
                Button("Try Again", action: tryAgain)
                Spacer()
                // The quiet one: it is the way on that leaves the problem.
                Button("Continue Anyway", action: continueAnyway)
                    .buttonStyle(.plain)
                    .font(Stanford.body(13))
                    .foregroundStyle(Stanford.interactive)
                    .help("\(appName) opens, and the work in these folders fails until access is allowed.")
            }
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: 560, alignment: .leading)
    }

    static let listedFolders = 3

    static func subject(_ count: Int) -> String {
        count == 1 ? "this workspace folder" : "\(count) workspace folders"
    }
}

private struct StartupFolderAccessPath: View {
    let folder: String

    var body: some View {
        Text((folder as NSString).abbreviatingWithTildeInPath)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Stanford.coolGrey)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
