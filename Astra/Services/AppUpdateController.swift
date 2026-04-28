import Combine
import Foundation
import Sparkle

@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    enum Status: Equatable {
        case disabled(String)
        case idle
        case checking
        case available(version: String)
        case notAvailable
        case blocked(String)
        case failed(String)
    }

    static let defaultFeedURL = "https://github.com/susom/astra/releases/latest/download/appcast.xml"

    @Published private(set) var status: Status
    @Published private(set) var canCheckForUpdates = false

    private var updaterController: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?
    private var isWorkActive: @MainActor () -> Bool = { false }
    private var prepareForInstall: @MainActor () -> Bool = { true }
    private var hasProbedForUpdates = false

    override init() {
        let disabledReason = Self.disabledReason()
        status = disabledReason.map(Status.disabled) ?? .idle
        super.init()

        guard disabledReason == nil else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        updaterController = controller
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            Task { @MainActor in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    var shouldShowUpdateButton: Bool {
        switch status {
        case .available, .blocked:
            return true
        case .disabled, .idle, .checking, .notAvailable, .failed:
            return false
        }
    }

    var buttonTitle: String {
        if case .available(let version) = status {
            return "Update \(version)"
        }
        return "Update"
    }

    var statusMessage: String? {
        switch status {
        case .disabled(let reason), .blocked(let reason), .failed(let reason):
            return reason
        case .available(let version):
            return "\(AppChannel.current.displayName) \(version) is available."
        case .checking:
            return "Checking for updates..."
        case .notAvailable:
            return "\(AppChannel.current.displayName) is up to date."
        case .idle:
            return nil
        }
    }

    func configureSafety(
        isWorkActive: @escaping @MainActor () -> Bool,
        prepareForInstall: @escaping @MainActor () -> Bool
    ) {
        self.isWorkActive = isWorkActive
        self.prepareForInstall = prepareForInstall
    }

    func probeForUpdatesOnce() {
        guard !hasProbedForUpdates, let updater = updaterController?.updater else { return }
        guard canCheckForUpdates || !updater.sessionInProgress else { return }
        hasProbedForUpdates = true
        status = .checking
        AppLogger.audit(.appUpdateCheckStarted, category: "Updater", fields: [
            "source": "probe"
        ])
        updater.checkForUpdateInformation()
    }

    func checkForUpdates() {
        guard let updater = updaterController?.updater else { return }
        guard !isWorkActive() else {
            markBlocked()
            return
        }
        status = .checking
        AppLogger.audit(.appUpdateCheckStarted, category: "Updater", fields: [
            "source": "manual"
        ])
        updater.checkForUpdates()
    }

    func checkForUpdatesFromButton() {
        checkForUpdates()
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        AppLogger.audit(.appUpdateCheckStarted, category: "Updater", fields: [
            "sparkle_check": String(describing: updateCheck)
        ])
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = .available(version: item.displayVersionString)
        AppLogger.audit(.appUpdateAvailable, category: "Updater", fields: [
            "version": item.versionString,
            "display_version": item.displayVersionString
        ])
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        status = .notAvailable
        AppLogger.audit(.appUpdateNotAvailable, category: "Updater", fields: [
            "error_type": String(describing: type(of: error))
        ])
    }

    func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        guard !isWorkActive() else {
            markBlocked(version: updateItem.displayVersionString)
            throw NSError(
                domain: "\(Bundle.main.bundleIdentifier ?? "com.coral.ASTRA").updater",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Finish or cancel running \(AppChannel.current.displayName) tasks before installing the update."
                ]
            )
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        AppLogger.audit(.appUpdateInstallRequested, category: "Updater", fields: [
            "version": item.versionString
        ])
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard prepareForInstall() else {
            markBlocked(version: item.displayVersionString)
            return true
        }
        return false
    }

    private func markBlocked(version: String? = nil) {
        let message = "Finish or cancel running \(AppChannel.current.displayName) tasks before installing the update."
        if let version {
            status = .blocked("\(AppChannel.current.displayName) \(version) is available. \(message)")
        } else {
            status = .blocked(message)
        }
        AppLogger.audit(.appUpdateBlocked, category: "Updater", fields: [
            "reason": "active_work"
        ], level: .warning)
    }

    private static func disabledReason() -> String? {
        let env = ProcessInfo.processInfo.environment
        if env["ASTRA_DISABLE_UPDATES"] == "1" {
            return "App updates are disabled for this launch."
        }
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--uitesting") }) {
            return "App updates are disabled during UI tests."
        }
        if AppChannel.current == .development {
            return "App updates are disabled for ASTRA Dev."
        }
        guard let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feedURL.isEmpty else {
            return "App updates are not configured for this build."
        }
        guard let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !publicKey.isEmpty else {
            return "App updates need a Sparkle public key for release builds."
        }
        return nil
    }
}
