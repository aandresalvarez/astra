import Foundation
import ASTRACore

struct ApplicationBundleMetadata: Equatable, Sendable {
    let displayName: String
    let version: String
    let bundleIdentifier: String

    static func read(from applicationURL: URL) throws -> ApplicationBundleMetadata {
        let infoURL = applicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        let data = try Data(contentsOf: infoURL)
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ApplicationInstallationError.invalidBundle(applicationURL)
        }

        let displayName = nonEmptyString(dictionary["CFBundleDisplayName"])
            ?? nonEmptyString(dictionary["CFBundleName"])
            ?? applicationURL.deletingPathExtension().lastPathComponent
        guard let version = nonEmptyString(dictionary["CFBundleShortVersionString"]),
              let bundleIdentifier = nonEmptyString(dictionary["CFBundleIdentifier"]) else {
            throw ApplicationInstallationError.invalidBundle(applicationURL)
        }

        return ApplicationBundleMetadata(
            displayName: displayName,
            version: version,
            bundleIdentifier: bundleIdentifier
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ApplicationInstallationPlan: Equatable, Sendable {
    let source: URL
    let destination: URL
    let sourceMetadata: ApplicationBundleMetadata
    let replacesExistingCopy: Bool
    let existingVersion: String?
}

enum ApplicationInstallationDecision: Equatable, Sendable {
    case present(ApplicationInstallationPlan)
    case unavailable
    case doNothing
}

enum ApplicationInstallationPlanner {
    typealias MetadataReader = (URL) -> ApplicationBundleMetadata?

    static func requiresInstallation(
        channel: AppChannel,
        currentBundleURL: URL,
        applicationsDirectories: [URL]
    ) -> Bool {
        guard channel != .development else { return false }
        let bundleName = "\(channel.displayName).app"
        let currentPath = currentBundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        return !applicationsDirectories.contains { directory in
            directory
                .appendingPathComponent(bundleName, isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path == currentPath
        }
    }

    static func decide(
        channel: AppChannel,
        currentBundleURL: URL,
        sourceMetadata: ApplicationBundleMetadata,
        applicationsDirectories: [URL],
        fileManager: FileManager,
        metadataReader: MetadataReader = { try? ApplicationBundleMetadata.read(from: $0) }
    ) -> ApplicationInstallationDecision {
        guard requiresInstallation(
            channel: channel,
            currentBundleURL: currentBundleURL,
            applicationsDirectories: applicationsDirectories
        ) else { return .doNothing }

        let bundleName = "\(channel.displayName).app"
        let destinations = applicationsDirectories.map {
            $0.appendingPathComponent(bundleName, isDirectory: true).standardizedFileURL
        }

        // Existing installed copies take precedence over every empty fallback.
        // Installing a second copy into ~/Applications is exactly what made the
        // old workflow appear unfinished and later triggered a Finder "Replace?"
        // loop. Replacement is now a first-class, visible plan.
        if let existingDestination = destinations.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return .present(
                ApplicationInstallationPlan(
                    source: currentBundleURL,
                    destination: existingDestination,
                    sourceMetadata: sourceMetadata,
                    replacesExistingCopy: true,
                    existingVersion: metadataReader(existingDestination)?.version
                )
            )
        }

        for (directory, destination) in zip(applicationsDirectories, destinations) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  fileManager.isWritableFile(atPath: directory.path) else {
                continue
            }

            return .present(
                ApplicationInstallationPlan(
                    source: currentBundleURL,
                    destination: destination,
                    sourceMetadata: sourceMetadata,
                    replacesExistingCopy: false,
                    existingVersion: nil
                )
            )
        }

        return .unavailable
    }
}

enum ApplicationInstallationError: LocalizedError {
    case invalidBundle(URL)
    case sourceAndDestinationMatch
    case destinationNotWritable(URL)
    case copiedBundleDoesNotMatch
    case installedBundleDoesNotMatch

    var errorDescription: String? {
        switch self {
        case .invalidBundle(let url):
            return "\(url.lastPathComponent) is not a complete macOS application."
        case .sourceAndDestinationMatch:
            return "ASTRA is already running from the Applications folder."
        case .destinationNotWritable(let url):
            return "ASTRA could not write to \(url.path)."
        case .copiedBundleDoesNotMatch:
            return "The copied application did not match the ASTRA release being installed."
        case .installedBundleDoesNotMatch:
            return "ASTRA could not verify the installed application."
        }
    }
}

enum ApplicationInstallationService {
    static func install(
        _ plan: ApplicationInstallationPlan,
        fileManager: FileManager = .default,
        stagingIdentifier: String = UUID().uuidString
    ) throws {
        let source = plan.source.standardizedFileURL
        let destination = plan.destination.standardizedFileURL
        guard source.path != destination.path else {
            throw ApplicationInstallationError.sourceAndDestinationMatch
        }

        let destinationDirectory = destination.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: destinationDirectory.path) else {
            throw ApplicationInstallationError.destinationNotWritable(destinationDirectory)
        }

        let actualSourceMetadata = try ApplicationBundleMetadata.read(from: source)
        guard actualSourceMetadata.bundleIdentifier == plan.sourceMetadata.bundleIdentifier,
              actualSourceMetadata.version == plan.sourceMetadata.version else {
            throw ApplicationInstallationError.copiedBundleDoesNotMatch
        }

        let stagingURL = destinationDirectory.appendingPathComponent(
            ".\(destination.lastPathComponent).installing-\(stagingIdentifier)",
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: stagingURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }

        defer {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        try fileManager.copyItem(at: source, to: stagingURL)
        let stagedMetadata = try ApplicationBundleMetadata.read(from: stagingURL)
        guard stagedMetadata.bundleIdentifier == plan.sourceMetadata.bundleIdentifier,
              stagedMetadata.version == plan.sourceMetadata.version else {
            throw ApplicationInstallationError.copiedBundleDoesNotMatch
        }

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: destination)
        }

        let installedMetadata = try ApplicationBundleMetadata.read(from: destination)
        guard installedMetadata.bundleIdentifier == plan.sourceMetadata.bundleIdentifier,
              installedMetadata.version == plan.sourceMetadata.version else {
            throw ApplicationInstallationError.installedBundleDoesNotMatch
        }
    }
}

enum ApplicationRelauncher {
    struct Command: Equatable, Sendable {
        let executableURL: URL
        let arguments: [String]
    }

    /// The installed app opens only after this process exits, which releases
    /// the persistent-store lease before the replacement process starts.
    static func command(processID: Int32, destination: URL) -> Command {
        Command(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "while kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.05; done; exec /usr/bin/open \"$2\"",
                "astra-relaunch",
                String(processID),
                destination.path
            ]
        )
    }

    static func schedule(processID: Int32, destination: URL) throws {
        let command = command(processID: processID, destination: destination)
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        try process.run()
    }
}
