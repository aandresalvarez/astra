import Darwin
import Foundation
import Observation
import SwiftData
import SwiftUI
import ASTRAModels

/// Finds out, before the main window is built, whether the workspace folders
/// answer.
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
/// window shows what it is waiting for. The main window is built only once
/// they have answered, which keeps the order its startup relies on: nothing
/// can be started before interrupted work is settled, because there is
/// nothing on screen to start it from.
///
/// Read-only and idempotent. It opens each folder and closes it, keeps
/// nothing, and decides nothing: a folder that is missing or refused answers
/// at once and the app goes on exactly as it did before.
@MainActor
@Observable
final class StartupFolderAccessGate {
    /// False until every folder has answered or the person chose not to wait.
    private(set) var isOpen: Bool
    /// The folder being waited on now, for the waiting view to name.
    private(set) var waitingOn: String?

    @ObservationIgnored private var wait: Task<Void, Never>?
    @ObservationIgnored private var startedAt: UInt64?
    @ObservationIgnored private let touch: @Sendable (String) -> Void

    init(
        startsOpen: Bool = StartupFolderAccessGate.isSkipped(arguments: ProcessInfo.processInfo.arguments),
        touch: @escaping @Sendable (String) -> Void = { StartupFolderAccessGate.touch($0) }
    ) {
        isOpen = startsOpen
        self.touch = touch
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

    /// Opens the gate once every folder has answered, however long that
    /// takes. Every window awaits the same wait, and `folders` is asked once.
    func open(folders: () -> [String]) async {
        guard !isOpen else { return }
        if let wait {
            await wait.value
            return
        }
        let unique = Self.unique(folders())
        startedAt = DispatchTime.now().uptimeNanoseconds
        let wait = Task { @MainActor in await self.waitForAnswers(from: unique) }
        self.wait = wait
        await wait.value
    }

    /// Opens the gate without the folders' answers. The main window's reads
    /// then wait on them where they always did.
    func skip() {
        guard !isOpen else { return }
        isOpen = true
        log(outcome: "skipped", folderCount: nil)
    }

    private func waitForAnswers(from folders: [String]) async {
        for folder in folders {
            // Once skipped, nothing is gained by asking the rest.
            guard !isOpen else { break }
            waitingOn = folder
            await Self.answer(from: folder, touch: touch)
        }
        waitingOn = nil
        guard !isOpen else { return }
        isOpen = true
        log(outcome: "answered", folderCount: folders.count)
    }

    private func log(outcome: String, folderCount: Int?) {
        var fields = ["outcome": outcome]
        if let folderCount { fields["folder_count"] = String(folderCount) }
        PerformanceTelemetry.log(
            "startup_folder_access",
            durationMilliseconds: startedAt.map { PerformanceTelemetry.elapsedMilliseconds(since: $0) },
            level: .info,
            fields: fields
        )
    }

    nonisolated private static let queue = DispatchQueue(label: "com.coral.astra.startup-folder-access", qos: .userInitiated)

    /// Runs `touch` on a queue of its own, never the cooperative pool a
    /// blocked open would starve, and returns when it has.
    nonisolated private static func answer(from folder: String, touch: @escaping @Sendable (String) -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                touch(folder)
                continuation.resume()
            }
        }
    }

    /// Opens the folder for reading and closes it. That is the access macOS
    /// asks permission for, and its cost does not grow with the folder.
    nonisolated static func touch(_ folder: String) {
        let descriptor = Darwin.open(folder, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    nonisolated private static func unique(_ folders: [String]) -> [String] {
        var seen = Set<String>()
        return folders.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Builds the main window's content only once the gate is open, and shows
/// what is being waited for until then.
struct StartupFolderAccessRoot<Content: View>: View {
    let gate: StartupFolderAccessGate
    let folders: () -> [String]
    @ViewBuilder let content: () -> Content

    var body: some View {
        if gate.isOpen {
            content()
        } else {
            StartupFolderAccessWaitingView(gate: gate)
                .task { await gate.open(folders: folders) }
        }
    }
}

/// Says nothing for a moment, since the folders normally answer at once.
/// After that it names the folder and offers the way past it.
struct StartupFolderAccessWaitingView: View {
    static let quietSeconds: Double = 1

    let gate: StartupFolderAccessGate
    @State private var showsWait = false

    var body: some View {
        // A stack, not a Group: while it shows nothing it must still be a
        // view, or neither this task nor the one that opens the gate runs.
        ZStack {
            if showsWait, let folder = gate.waitingOn {
                StartupFolderAccessNotice(folder: folder) { gate.skip() }
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

/// What the waiting window says: the folder, why the app may be waiting on
/// it, and the one way past it.
struct StartupFolderAccessNotice: View {
    let folder: String
    let continueWithoutWaiting: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Waiting for folder access")
                .font(Stanford.heading(22))
                .foregroundStyle(Stanford.black)
            Text("ASTRA is waiting to read a workspace folder. If macOS is asking for permission, answer it to continue.")
                .font(Stanford.body(14))
                .foregroundStyle(Stanford.coolGrey)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.displayPath(folder))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Stanford.coolGrey)
                .textSelection(.enabled)
            // Not the accent button: answering macOS is the way forward, and
            // this one trades the wait for an app that may stop responding.
            Button("Continue Without Waiting", action: continueWithoutWaiting)
                .help("ASTRA may stop responding until the folder answers.")
        }
        .padding(32)
        .frame(maxWidth: 520, alignment: .leading)
    }

    static func displayPath(_ folder: String) -> String {
        (folder as NSString).abbreviatingWithTildeInPath
    }
}
