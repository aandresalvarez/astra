import Foundation
import Testing
@testable import ASTRA

/// `.claude/settings.local.json` is the one file ASTRA rewrites that sibling
/// launches in one checkout share. These pin how that write is coordinated.
@Suite("Claude checkout settings shared write")
struct ClaudeSettingsSharedWriteTests {
    private func makeCheckout() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-claude-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func identity(_ path: String) throws -> (inode: UInt64, text: String) {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return ((attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                try String(contentsOfFile: path, encoding: .utf8))
    }

    @Test("A launch whose permissions the file already carries does not rewrite it")
    func unchangedProjectionLeavesTheFileAlone() throws {
        let checkout = try makeCheckout()
        defer { try? FileManager.default.removeItem(atPath: checkout) }
        let path = ClaudeSettingsStore.settingsPath(for: checkout)

        #expect(ClaudeSettingsStore.ensureSubAgentPermissions(at: checkout, policy: .restricted, allowedTools: ["Read", "Grep"]))
        let first = try identity(path)

        // A sibling launch with the same policy: same file, same bytes, and
        // no new `updatedAt` stamp.
        #expect(ClaudeSettingsStore.ensureSubAgentPermissions(at: checkout, policy: .restricted, allowedTools: ["Read", "Grep"]))
        let second = try identity(path)
        #expect(second.inode == first.inode)
        #expect(second.text == first.text)
    }

    @Test("A different projection replaces the file whole")
    func changedProjectionReplacesTheFile() throws {
        let checkout = try makeCheckout()
        defer { try? FileManager.default.removeItem(atPath: checkout) }
        let path = ClaudeSettingsStore.settingsPath(for: checkout)

        #expect(ClaudeSettingsStore.ensureSubAgentPermissions(at: checkout, policy: .restricted, allowedTools: ["Read"]))
        let first = try identity(path)
        #expect(ClaudeSettingsStore.ensureSubAgentPermissions(at: checkout, policy: .restricted, allowedTools: ["Read", "Grep"]))
        let second = try identity(path)

        // Written beside the old file and moved into place: a reader holding
        // the old file keeps complete settings.
        #expect(second.inode != first.inode)
        let settings = try #require(JSONSerialization.jsonObject(with: Data(second.text.utf8)) as? [String: Any])
        let allow = (settings["permissions"] as? [String: Any])?["allow"] as? [String] ?? []
        #expect(allow.contains("Grep(*)"))
        #expect(settings["_astra_policy"] != nil)
    }

    @Test("Permissions a user wrote by hand are still adopted once")
    func userWrittenPermissionsGainTheMarker() throws {
        let checkout = try makeCheckout()
        defer { try? FileManager.default.removeItem(atPath: checkout) }
        let path = ClaudeSettingsStore.settingsPath(for: checkout)
        #expect(ClaudeSettingsStore.ensureSubAgentPermissions(at: checkout, policy: .autonomous, allowedTools: []))
        var settings = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        settings.removeValue(forKey: "_astra_policy")
        try JSONSerialization.data(withJSONObject: settings).write(to: URL(fileURLWithPath: path))

        #expect(ClaudeSettingsStore.ensureSubAgentPermissions(at: checkout, policy: .autonomous, allowedTools: []))
        let rewritten = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        #expect(rewritten["_astra_policy"] != nil)
    }

    @Test("Rewriting a restricted settings file keeps its permissions and extended attributes")
    func rewriteKeepsFileMetadata() throws {
        let checkout = try makeCheckout()
        defer { try? FileManager.default.removeItem(atPath: checkout) }
        let path = ClaudeSettingsStore.settingsPath(for: checkout)
        #expect(ClaudeSettingsStore.ensureSubAgentPermissions(at: checkout, policy: .restricted, allowedTools: ["Read"]))
        // The owner restricts the file and tags it.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let tag = Array("kept".utf8)
        #expect(setxattr(path, "com.astra.test.tag", tag, tag.count, 0, 0) == 0)

        // A different projection replaces the file.
        #expect(ClaudeSettingsStore.ensureSubAgentPermissions(at: checkout, policy: .autonomous, allowedTools: ["Read", "Bash"]))

        let mode = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        var buffer = [UInt8](repeating: 0, count: 16)
        let length = getxattr(path, "com.astra.test.tag", &buffer, buffer.count, 0, 0)
        #expect(length == tag.count)
        #expect(Array(buffer.prefix(max(0, length))) == tag)
        // No staging file is left beside it.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent)
        #expect(siblings == [(path as NSString).lastPathComponent])
    }

    @Test("A symlinked settings file keeps its link")
    func symlinkedSettingsFileSurvives() throws {
        let checkout = try makeCheckout()
        defer { try? FileManager.default.removeItem(atPath: checkout) }
        let directory = ClaudeSettingsStore.settingsDirectory(for: checkout)
        let path = ClaudeSettingsStore.settingsPath(for: checkout)
        let target = (checkout as NSString).appendingPathComponent("shared-settings.json")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try #"{"custom":true}"#.write(toFile: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)

        #expect(ClaudeSettingsStore.ensureSubAgentPermissions(at: checkout, policy: .autonomous, allowedTools: []))

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path) == target)
        let settings = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: target))) as? [String: Any])
        #expect(settings["custom"] as? Bool == true)
        #expect(settings["permissions"] != nil)
    }
}
