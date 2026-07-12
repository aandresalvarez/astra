import Foundation
import ASTRACore

struct ValidatedFeedbackPackage {
    let envelope: FeedbackReportEnvelopeV1
    let envelopeData: Data
    let manifest: FeedbackEvidenceManifestV1
    let manifestSHA256: String
    let reportSHA256: String
    let archiveSHA256: String?
}

enum FeedbackPackageLayout {
    static let envelope = "feedback-report.json"
    static let manifest = "manifest.json"
    static let archive = "evidence.zip"
}

enum FeedbackPackageValidationError: Error, Equatable {
    case sourceIsNotDirectory
    case symbolicLink(String)
    case unsafeRelativePath(String)
    case missingFile(String)
    case unexpectedFile(String)
    case manifestMismatch
    case byteCountMismatch(String)
    case hashMismatch(String)
    case archiveDisclosureMismatch
    case archiveToolUnavailable
    case archiveContentsMismatch(String)
    case nonCanonicalEnvelope
    case nonCanonicalManifest
    case forbiddenContactMember
}

enum FeedbackPackageAdoptionValidator {
    static func validate(
        directory: URL,
        fileManager: FileManager = .default
    ) throws -> ValidatedFeedbackPackage {
        let canonicalDirectory = directory.standardizedFileURL
        let sourceValues = try canonicalDirectory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])
        guard sourceValues.isDirectory == true, sourceValues.isSymbolicLink != true else {
            throw FeedbackPackageValidationError.sourceIsNotDirectory
        }

        let envelopeURL = canonicalDirectory.appendingPathComponent(FeedbackPackageLayout.envelope)
        let manifestURL = canonicalDirectory.appendingPathComponent(FeedbackPackageLayout.manifest)
        let envelopeData = try requiredData(
            at: envelopeURL,
            relativePath: FeedbackPackageLayout.envelope,
            fileManager: fileManager
        )
        let manifestData = try requiredData(
            at: manifestURL,
            relativePath: FeedbackPackageLayout.manifest,
            fileManager: fileManager
        )

        guard FeedbackRawCanonicalJSONVerifier.isCanonicalObject(envelopeData) else {
            throw FeedbackPackageValidationError.nonCanonicalEnvelope
        }
        guard !FeedbackContactMemberPolicy.containsForbiddenMember(in: envelopeData) else {
            throw FeedbackPackageValidationError.forbiddenContactMember
        }

        let envelope = try FeedbackCanonicalJSONV1.decode(
            FeedbackReportEnvelopeV1.self,
            from: envelopeData
        )
        try envelope.validate()

        let manifest = try FeedbackCanonicalJSONV1.decode(
            FeedbackEvidenceManifestV1.self,
            from: manifestData
        ).canonicalized()
        try manifest.validate()
        guard manifestData == (try FeedbackCanonicalJSONV1.encodeValidated(manifest)) else {
            throw FeedbackPackageValidationError.nonCanonicalManifest
        }
        guard manifest == envelope.payload.evidence.canonicalized() else {
            throw FeedbackPackageValidationError.manifestMismatch
        }

        var allowedFiles: Set<String> = [
            FeedbackPackageLayout.envelope,
            FeedbackPackageLayout.manifest
        ]

        let artifactPaths = try manifest.artifacts.map { artifact in
            let relativePath = try safeRelativePath(artifact.relativePath)
            allowedFiles.insert(relativePath)
            return (artifact, relativePath)
        }

        let archiveURL = canonicalDirectory.appendingPathComponent(FeedbackPackageLayout.archive)
        if envelope.evidenceArchiveSHA256 != nil {
            allowedFiles.insert(FeedbackPackageLayout.archive)
        } else if fileManager.fileExists(atPath: archiveURL.path) {
            throw FeedbackPackageValidationError.archiveDisclosureMismatch
        }

        try validateInventory(
            directory: canonicalDirectory,
            allowedFiles: allowedFiles,
            fileManager: fileManager
        )

        var artifactBytes: [(artifact: FeedbackEvidenceArtifactV1, relativePath: String, data: Data)] = []
        for (artifact, relativePath) in artifactPaths {
            let url = canonicalDirectory.appendingPathComponent(relativePath)
            let data = try requiredData(
                at: url,
                relativePath: relativePath,
                fileManager: fileManager
            )
            guard data.count == Int(artifact.byteCount) else {
                throw FeedbackPackageValidationError.byteCountMismatch(relativePath)
            }
            guard FeedbackCanonicalJSONV1.sha256Hex(data) == artifact.sha256 else {
                throw FeedbackPackageValidationError.hashMismatch(relativePath)
            }
            artifactBytes.append((artifact, relativePath, data))
        }

        var actualArchiveSHA256: String?
        if let expectedArchiveHash = envelope.evidenceArchiveSHA256 {
            let archiveData = try requiredData(
                at: archiveURL,
                relativePath: FeedbackPackageLayout.archive,
                fileManager: fileManager
            )
            let archiveSHA256 = FeedbackCanonicalJSONV1.sha256Hex(archiveData)
            guard archiveSHA256 == expectedArchiveHash else {
                throw FeedbackPackageValidationError.hashMismatch(FeedbackPackageLayout.archive)
            }
            try FeedbackEvidenceArchiveValidator.validate(
                archiveURL: archiveURL,
                artifacts: artifactBytes,
                fileManager: fileManager
            )
            actualArchiveSHA256 = archiveSHA256
        }
        return ValidatedFeedbackPackage(
            envelope: envelope,
            envelopeData: envelopeData,
            manifest: manifest,
            manifestSHA256: FeedbackCanonicalJSONV1.sha256Hex(manifestData),
            reportSHA256: FeedbackCanonicalJSONV1.sha256Hex(envelopeData),
            archiveSHA256: actualArchiveSHA256
        )
    }

    private static func requiredData(
        at url: URL,
        relativePath: String,
        fileManager: FileManager
    ) throws -> Data {
        guard fileManager.fileExists(atPath: url.path) else {
            throw FeedbackPackageValidationError.missingFile(relativePath)
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            throw FeedbackPackageValidationError.symbolicLink(relativePath)
        }
        guard values.isRegularFile == true else {
            throw FeedbackPackageValidationError.unexpectedFile(relativePath)
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private static func safeRelativePath(_ path: String) throws -> String {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("."),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("") else {
            throw FeedbackPackageValidationError.unsafeRelativePath(path)
        }
        return path
    }

    private static func validateInventory(
        directory: URL,
        allowedFiles: Set<String>,
        fileManager: FileManager
    ) throws {
        let allowedDirectories = Set(allowedFiles.flatMap { path -> [String] in
            let components = path.split(separator: "/").dropLast()
            return components.indices.map { index in
                components.prefix(index + 1).joined(separator: "/")
            }
        })
        for relative in try fileManager.subpathsOfDirectory(atPath: directory.path) {
            let url = directory.appendingPathComponent(relative)
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            if values.isSymbolicLink == true {
                throw FeedbackPackageValidationError.symbolicLink(relative)
            }
            if values.isDirectory == true {
                guard allowedDirectories.contains(relative) else {
                    throw FeedbackPackageValidationError.unexpectedFile(relative)
                }
            } else if values.isRegularFile != true || !allowedFiles.contains(relative) {
                throw FeedbackPackageValidationError.unexpectedFile(relative)
            }
        }
    }
}
