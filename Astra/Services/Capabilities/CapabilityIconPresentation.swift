import Foundation
import ASTRACore

enum CapabilityBrandIcon: String, Equatable, CaseIterable {
    case github
    case jira
    case googleDrive
    case googleCloud
    case microsoft365

    init?(descriptorValue: String) {
        let normalized = CapabilityIconPresentation.normalized(descriptorValue)
        switch normalized {
        case "github":
            self = .github
        case "jira", "atlassian":
            self = .jira
        case "googledrive", "google-drive", "drive":
            self = .googleDrive
        case "googlecloud", "google-cloud", "gcloud":
            self = .googleCloud
        case "microsoft365", "microsoft-365", "office365", "graph":
            self = .microsoft365
        default:
            return nil
        }
    }
}

struct CapabilityIconPresentation: Equatable {
    enum Kind: Equatable {
        case systemSymbol(String)
        case brand(CapabilityBrandIcon)
        case asset(URL)
    }

    let kind: Kind
    let fallbackSystemName: String
    let monochromePreferred: Bool

    init(
        kind: Kind,
        fallbackSystemName: String,
        monochromePreferred: Bool = true
    ) {
        self.kind = kind
        self.fallbackSystemName = fallbackSystemName
        self.monochromePreferred = monochromePreferred
    }

    static func make(for package: PluginPackage) -> CapabilityIconPresentation {
        let explicitDescriptor = package.iconDescriptor == .systemSymbol(package.icon) ? nil : package.iconDescriptor
        return make(
            name: package.name,
            packageID: package.id,
            fallbackSystemName: package.icon,
            descriptor: explicitDescriptor,
            sourceURL: package.sourceMetadata?.url,
            tags: package.tags,
            browserAdapters: package.browserAdapters
        )
    }

    static func make(
        name: String,
        packageID: String? = nil,
        fallbackSystemName: String,
        descriptor: CapabilityIconDescriptor? = nil,
        sourceURL: URL? = nil,
        tags: [String] = [],
        browserAdapters: [String] = []
    ) -> CapabilityIconPresentation {
        let fallback = cleanSystemName(fallbackSystemName)
        if let descriptorPresentation = presentation(for: descriptor, sourceURL: sourceURL) {
            return descriptorPresentation
        }

        let normalizedName = normalized(name)
        let normalizedID = normalized(packageID ?? "")

        if isGitHubCapability(
            normalizedName: normalizedName,
            normalizedID: normalizedID,
            tags: tags,
            browserAdapters: browserAdapters
        ) {
            return CapabilityIconPresentation(kind: .brand(.github), fallbackSystemName: fallback)
        }
        if normalizedID == "jira-workflow" ||
            normalizedName.contains("jira") ||
            tags.contains(where: { normalized($0) == "jira" }) {
            return CapabilityIconPresentation(kind: .brand(.jira), fallbackSystemName: fallback)
        }
        if normalizedID == "google-drive-browser" ||
            normalizedName.contains("google drive") ||
            tags.contains(where: { normalized($0) == "googledrive" || normalized($0) == "drive" }) {
            return CapabilityIconPresentation(kind: .brand(.googleDrive), fallbackSystemName: fallback)
        }
        if normalizedID == "gcloud-workflow" ||
            normalizedName.contains("google cloud") ||
            tags.contains(where: { normalized($0) == "googlecloud" || normalized($0) == "gcloud" }) {
            return CapabilityIconPresentation(kind: .brand(.googleCloud), fallbackSystemName: fallback)
        }

        if normalizedName.contains("bigquery") {
            return CapabilityIconPresentation(kind: .systemSymbol("cylinder.split.1x2"), fallbackSystemName: fallback)
        }
        if normalizedName.contains("read-only") || normalizedName.contains("read only") {
            return CapabilityIconPresentation(kind: .systemSymbol("eye"), fallbackSystemName: fallback)
        }
        if normalizedName.contains("safe bash") {
            return CapabilityIconPresentation(kind: .systemSymbol("terminal"), fallbackSystemName: fallback)
        }

        return CapabilityIconPresentation(kind: .systemSymbol(fallback), fallbackSystemName: fallback)
    }

    var legacySystemName: String {
        switch kind {
        case .systemSymbol(let name):
            name
        case .brand, .asset:
            fallbackSystemName
        }
    }

    private static func isGitHubCapability(
        normalizedName: String,
        normalizedID: String,
        tags: [String],
        browserAdapters: [String]
    ) -> Bool {
        if normalizedID == "github-workflow" {
            return true
        }
        if normalizedName == "github" || normalizedName.contains("github ") || normalizedName.contains("github-") {
            return true
        }
        if tags.contains(where: { normalized($0) == "github" }) {
            return true
        }
        return browserAdapters.contains { normalized($0) == "github" }
    }

    private static func presentation(
        for descriptor: CapabilityIconDescriptor?,
        sourceURL: URL?
    ) -> CapabilityIconPresentation? {
        guard let descriptor else { return nil }
        let descriptorFallback = cleanSystemName(descriptor.fallbackSystemName)
        switch descriptor.kind {
        case .systemSymbol:
            return CapabilityIconPresentation(
                kind: .systemSymbol(cleanSystemName(descriptor.value)),
                fallbackSystemName: descriptorFallback
            )
        case .brand:
            guard let brand = CapabilityBrandIcon(descriptorValue: descriptor.value) else {
                return nil
            }
            return CapabilityIconPresentation(kind: .brand(brand), fallbackSystemName: descriptorFallback)
        case .asset:
            guard let assetURL = assetURL(relativePath: descriptor.value, sourceURL: sourceURL) else {
                return CapabilityIconPresentation(kind: .systemSymbol(descriptorFallback), fallbackSystemName: descriptorFallback)
            }
            return CapabilityIconPresentation(
                kind: .asset(assetURL),
                fallbackSystemName: descriptorFallback,
                monochromePreferred: descriptor.monochromePreferred
            )
        }
    }

    private static func assetURL(relativePath: String, sourceURL: URL?) -> URL? {
        guard let sourceURL,
              let normalized = CapabilityIconAssetPolicy.normalizedRelativePath(relativePath) else {
            return nil
        }
        let isDirectory = (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let rootURL = isDirectory ? sourceURL : sourceURL.deletingLastPathComponent()
        let url = rootURL.appendingPathComponent(normalized, isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func cleanSystemName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "puzzlepiece.extension" : trimmed
    }

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
