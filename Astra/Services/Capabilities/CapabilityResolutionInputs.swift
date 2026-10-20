import Foundation
import ASTRACore

/// The disk-backed inputs of capability resolution, read once for a whole
/// evaluation.
///
/// Admission resolves capabilities once per runtime it scores, and each pass
/// asks for the package catalog many times over. Each ask re-listed the
/// Capabilities folder to fingerprint it, a workspace with packs re-read and
/// re-decoded the whole pack catalog, and policy gating re-read the approval
/// records. From the composer's eligibility preview, all of that ran on the
/// main actor after every typing pause (prod sample, 2026-10-20).
///
/// `load()` does the reads and is safe off the main actor. Inside `pinned`,
/// the three readers (`CapabilityRuntimeResourceMatcher.packageDefinitions`,
/// `AstraPackCatalog.load`, `CapabilityApprovalStore.records`) return these
/// values instead of touching the disk. That applies only to the default
/// storage locations, so a caller that names its own directory still reads it.
/// Nothing is cached across evaluations: every evaluation loads afresh, as
/// freshly as before, just not on the main actor.
struct CapabilityResolutionInputs: Sendable {
    let libraryDirectory: URL
    let packageDefinitions: [PluginPackage]
    let approvalsDirectory: URL
    let approvalRecords: [CapabilityApprovalRecord]
    let packBuiltInDirectory: URL?
    let packLocalStorageRoot: URL?
    let packCatalog: AstraPackCatalogSnapshot

    @TaskLocal static var pinned: CapabilityResolutionInputs?

    /// Counts the disk reads those readers make. Lets a test prove a pinned
    /// evaluation makes none; it is nil, and costs nothing, everywhere else.
    @TaskLocal static var diskReadProbe: DiskReadProbe?

    final class DiskReadProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [Reader: Int] = [:]

        enum Reader: Hashable, Sendable {
            case capabilityLibrary
            case approvalRecords
            case packCatalog
        }

        func record(_ reader: Reader) {
            lock.lock()
            counts[reader, default: 0] += 1
            lock.unlock()
        }

        func count(_ reader: Reader) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return counts[reader, default: 0]
        }
    }

    /// Reads every input from its default location. Must not run inside a pin,
    /// or it would hand back the pinned values instead of re-reading.
    static func load(
        library: CapabilityLibrary = CapabilityLibrary(),
        approvals: CapabilityApprovalStore = CapabilityApprovalStore(),
        packCatalog: AstraPackCatalog = AstraPackCatalog()
    ) -> CapabilityResolutionInputs {
        CapabilityResolutionInputs.$pinned.withValue(nil) {
            CapabilityResolutionInputs(
                libraryDirectory: library.directory.standardizedFileURL,
                packageDefinitions: CapabilityRuntimeResourceMatcher.packageDefinitions(library: library),
                approvalsDirectory: approvals.directory.standardizedFileURL,
                approvalRecords: approvals.records(),
                packBuiltInDirectory: packCatalog.builtInDirectory?.standardizedFileURL,
                packLocalStorageRoot: packCatalog.localStorageRoot?.standardizedFileURL,
                packCatalog: packCatalog.load()
            )
        }
    }

    /// `load()` on a background thread, for callers on the main actor.
    static func loadDetached() async -> CapabilityResolutionInputs {
        await Task.detached(priority: .userInitiated) { load() }.value
    }

    // MARK: - Reader hooks

    static func pinnedPackageDefinitions(for library: CapabilityLibrary) -> [PluginPackage]? {
        guard let pinned, pinned.libraryDirectory == library.directory.standardizedFileURL else {
            diskReadProbe?.record(.capabilityLibrary)
            return nil
        }
        return pinned.packageDefinitions
    }

    static func pinnedApprovalRecords(for directory: URL) -> [CapabilityApprovalRecord]? {
        guard let pinned, pinned.approvalsDirectory == directory.standardizedFileURL else {
            diskReadProbe?.record(.approvalRecords)
            return nil
        }
        return pinned.approvalRecords
    }

    static func pinnedPackCatalog(builtInDirectory: URL?, localStorageRoot: URL?) -> AstraPackCatalogSnapshot? {
        guard let pinned,
              pinned.packBuiltInDirectory == builtInDirectory?.standardizedFileURL,
              pinned.packLocalStorageRoot == localStorageRoot?.standardizedFileURL else {
            diskReadProbe?.record(.packCatalog)
            return nil
        }
        return pinned.packCatalog
    }
}
