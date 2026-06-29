import Foundation

struct AstraPackSource: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case builtIn
        case local
    }

    var kind: Kind
    var manifestURL: URL?
    var rootURL: URL?
    var displayName: String
    var rawData: Data?

    static func readJSONFiles(
        in directory: URL?,
        kind: Kind,
        fileManager: FileManager = .default
    ) -> AstraPackSourceReadResult {
        guard let directory else {
            return AstraPackSourceReadResult(sources: [], failures: [])
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return AstraPackSourceReadResult(sources: [], failures: [])
        }

        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { lhs, rhs in
                lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
            }
        } catch {
            let source = AstraPackSource(
                kind: kind,
                manifestURL: directory,
                rootURL: directory,
                displayName: displayName(for: kind),
                rawData: nil
            )
            return AstraPackSourceReadResult(
                sources: [],
                failures: [AstraPackSourceReadFailure(source: source, error: error)]
            )
        }

        let broker = HostFileAccessBroker(fileManager: fileManager)
        var sources: [AstraPackSource] = []
        var failures: [AstraPackSourceReadFailure] = []
        for url in urls {
            let source = AstraPackSource(
                kind: kind,
                manifestURL: url,
                rootURL: directory,
                displayName: displayName(for: kind),
                rawData: nil
            )
            do {
                let data = try broker.readData(
                    at: url,
                    intent: .astraManagedStorage(root: directory)
                )
                var loadedSource = source
                loadedSource.rawData = data
                sources.append(loadedSource)
            } catch {
                failures.append(AstraPackSourceReadFailure(source: source, error: error))
            }
        }

        return AstraPackSourceReadResult(sources: sources, failures: failures)
    }

    private static func displayName(for kind: Kind) -> String {
        switch kind {
        case .builtIn:
            return "Built-in Packs"
        case .local:
            return "Local Packs"
        }
    }
}

struct AstraPackSourceReadResult: Equatable {
    var sources: [AstraPackSource]
    var failures: [AstraPackSourceReadFailure]
}

struct AstraPackSourceReadFailure: Equatable {
    var source: AstraPackSource
    var error: Error

    static func == (lhs: AstraPackSourceReadFailure, rhs: AstraPackSourceReadFailure) -> Bool {
        lhs.source == rhs.source
    }
}
