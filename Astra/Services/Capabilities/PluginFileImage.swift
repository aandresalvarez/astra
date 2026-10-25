import Foundation
import Darwin
import ASTRAPersistence

/// Bounded, literal library/approval bytes. Never stores Keychain values or
/// follows links. Images can be replayed repeatedly after an interrupted copy.
struct PluginFileImage: Codable, Equatable {
    enum Failure: Error { case unsafeEntry, tooLarge }
    let isDirectory: Bool
    let directories: [String]
    let files: [String: Data]
    static let maximumBytes = 32 * 1_024 * 1_024
    private static let maximumEntries = 1_024

    static func capture(_ url: URL) throws -> Self? {
        let manager = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do { attributes = try manager.attributesOfItem(atPath: url.path) }
        catch where WorkspaceFileLayout.isMissingFile(error) { return nil }
        let type = attributes[.type] as? FileAttributeType
        if type == .typeRegular {
            return try Self(isDirectory: false, directories: [], files: ["": read(url)]).validated()
        }
        guard type == .typeDirectory else { throw Failure.unsafeEntry }
        var directories: [String] = [], files: [String: Data] = [:], bytes = 0
        func visit(_ folder: URL, prefix: String, depth: Int) throws {
            guard depth < 16 else { throw Failure.tooLarge }
            for child in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                guard directories.count + files.count < maximumEntries else { throw Failure.tooLarge }
                let path = prefix + child.lastPathComponent
                guard valid(path) else { throw Failure.unsafeEntry }
                let type = try manager.attributesOfItem(atPath: child.path)[.type] as? FileAttributeType
                if type == .typeDirectory {
                    directories.append(path)
                    try visit(child, prefix: path + "/", depth: depth + 1)
                } else if type == .typeRegular {
                    let data = try read(child, limit: maximumBytes - bytes)
                    bytes += data.count
                    files[path] = data
                } else { throw Failure.unsafeEntry }
            }
        }
        try visit(url, prefix: "", depth: 0)
        return try Self(isDirectory: true, directories: directories.sorted(), files: files).validated()
    }

    func validated() throws -> Self {
        guard directories.count + files.count <= Self.maximumEntries,
              files.values.reduce(0, { $0 + $1.count }) <= Self.maximumBytes else { throw Failure.tooLarge }
        if !isDirectory {
            guard directories.isEmpty, files.count == 1, files[""] != nil else { throw Failure.unsafeEntry }
        } else {
            guard Set(directories).count == directories.count,
                  directories.allSatisfy(Self.valid), files.keys.allSatisfy(Self.valid),
                  Set(directories).isDisjoint(with: files.keys) else { throw Failure.unsafeEntry }
            let folders = Set(directories)
            for path in directories + Array(files.keys) {
                let parts = path.split(separator: "/").map(String.init)
                for length in 1..<parts.count {
                    guard folders.contains(parts.prefix(length).joined(separator: "/")) else { throw Failure.unsafeEntry }
                }
            }
        }
        return self
    }

    func write(to url: URL) throws {
        _ = try validated()
        if !isDirectory { try files[""]!.write(to: url, options: .atomic); return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        for path in directories.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(path), withIntermediateDirectories: false)
        }
        for (path, data) in files { try data.write(to: url.appendingPathComponent(path), options: .atomic) }
    }

    static func valid(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }
    }

    private static func read(_ url: URL, limit: Int = maximumBytes) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { throw Failure.unsafeEntry }
        guard status.st_size <= limit else { throw Failure.tooLarge }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, limit + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= limit else { throw Failure.tooLarge }
        }
        return data
    }
}
