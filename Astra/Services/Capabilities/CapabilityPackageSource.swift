import CryptoKit
import Foundation
import ASTRACore

struct CapabilityPackageSource {
    var package: PluginPackage
    var manifestURL: URL?
    var assetRootURL: URL?
    var manifestData: Data?

    init(
        package: PluginPackage,
        manifestURL: URL?,
        assetRootURL: URL?,
        manifestData: Data? = nil
    ) {
        self.package = package
        self.manifestURL = manifestURL
        self.assetRootURL = assetRootURL
        self.manifestData = manifestData
    }

    var declaredIconAssetPath: String? {
        guard package.iconDescriptor.kind == .asset else { return nil }
        return package.iconDescriptor.value
    }

    func iconAssetURL() -> URL? {
        guard let relativePath = declaredIconAssetPath,
              let assetRootURL,
              let normalized = CapabilityIconAssetPolicy.normalizedRelativePath(relativePath) else {
            return nil
        }
        return assetRootURL.appendingPathComponent(normalized, isDirectory: false)
    }
}

enum CapabilityPackageSourceReadError: Error {
    case unreadable(URL, Error)
    case missingManifest(URL)
    case malformedManifest(URL, Error)
}

enum CapabilityPackageSourceReader {
    static let manifestFileName = "capability.json"

    static func read(at url: URL, fileManager: FileManager = .default) throws -> CapabilityPackageSource {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let manifestURL = isDirectory ? url.appendingPathComponent(manifestFileName) : url
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw CapabilityPackageSourceReadError.missingManifest(manifestURL)
        }

        let data: Data
        do {
            data = try HostFileAccessBroker(fileManager: fileManager).readData(
                at: manifestURL,
                intent: .explicitUserSelection
            )
        } catch {
            throw CapabilityPackageSourceReadError.unreadable(manifestURL, error)
        }

        do {
            let package = try JSONDecoder().decode(PluginPackage.self, from: data)
            return CapabilityPackageSource(
                package: package,
                manifestURL: manifestURL,
                assetRootURL: isDirectory ? url : manifestURL.deletingLastPathComponent(),
                manifestData: data
            )
        } catch {
            throw CapabilityPackageSourceReadError.malformedManifest(manifestURL, error)
        }
    }
}

enum CapabilityIconAssetPolicy {
    static let allowedExtensions: Set<String> = ["pdf", "png", "svg"]
    static let maxBytes = 512 * 1024

    static func normalizedRelativePath(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("://"),
              !trimmed.hasPrefix("/"),
              trimmed.hasPrefix("assets/") else {
            return nil
        }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }

        let ext = URL(fileURLWithPath: trimmed).pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else {
            return nil
        }

        return trimmed
    }

    static func invalidReason(for descriptor: CapabilityIconDescriptor) -> String? {
        guard descriptor.kind == .asset else { return nil }
        guard normalizedRelativePath(descriptor.value) != nil else {
            return "Asset icons must use a relative assets/ path with a pdf, png, or svg extension."
        }
        return nil
    }

    static func validatedAssetURL(
        relativePath: String,
        rootURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let normalized = normalizedRelativePath(relativePath) else {
            throw CapabilityIconAssetValidationError.invalidPath
        }

        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let assetURL = rootURL.appendingPathComponent(normalized, isDirectory: false)
        let resolvedAssetURL = assetURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedAssetURL.path.hasPrefix(root.path + "/") else {
            throw CapabilityIconAssetValidationError.invalidPath
        }
        guard fileManager.fileExists(atPath: assetURL.path) else {
            throw CapabilityIconAssetValidationError.missing
        }
        let values = try assetURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true,
              values.isRegularFile == true else {
            throw CapabilityIconAssetValidationError.invalidPath
        }
        guard (values.fileSize ?? 0) <= maxBytes else {
            throw CapabilityIconAssetValidationError.tooLarge
        }
        return assetURL
    }

    static func sha256Hex(for url: URL) throws -> String {
        let data = try HostFileAccessBroker().readData(
            at: url,
            intent: .astraManagedStorage(root: url.deletingLastPathComponent())
        )
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum CapabilityIconAssetValidationError: Error {
    case invalidPath
    case missing
    case tooLarge
}
