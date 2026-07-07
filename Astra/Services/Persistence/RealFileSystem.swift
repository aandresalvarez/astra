import Foundation
import ASTRACore

public struct RealFileSystem: FileSystem {
    public init() {}

    public func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
    }

    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func fileExists(atPath path: String, isDirectory: inout Bool) -> Bool {
        var objectiveCDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &objectiveCDirectory)
        isDirectory = objectiveCDirectory.boolValue
        return exists
    }

    public func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
    }
}
