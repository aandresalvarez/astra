// Standalone opt-in tool; never linked into either app. See dev-scale-benchmark.md.
import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

@main
struct DevWorkspaceFixture {
    static let seed: UInt64 = 0xA57A
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    static func id(_ kind: Int, _ index: Int) -> UUID {
        UUID(uuidString: String(format: "%08X-0000-4000-8000-%012llX", kind * 1_000_000 + index, UInt64(index) + seed))!
    }
    static func json(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4, ["seed", "resume", "verify", "sidebar"].contains(args[1]), ["full", "no-files", "sidebar-23", "sidebar-4", "sidebar-23-small", "sidebar-4-small"].contains(args[3]) else {
            fail("usage: fixture seed|resume|verify|sidebar ROOT full|no-files|sidebar-23|sidebar-4")
        }
        let root = URL(fileURLWithPath: args[2]).standardizedFileURL
        let profile = args[3]
        let sidebarOnly = profile.hasPrefix("sidebar-")
        let workspaceCount = profile.hasPrefix("sidebar-4") ? 4 : 23
        let taskCount = profile.hasSuffix("-small") ? 17 : 2195
        let store = root.appendingPathComponent("default.store")
        let fm = FileManager.default
        if args[1] == "seed" {
            guard !fm.fileExists(atPath: root.path) else { fail("seed root must not exist") }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try json(["format": 1, "seed": seed, "profile": profile], to: root.appendingPathComponent("synthetic-fixture.json"))
        } else {
            let manifest = try Data(contentsOf: root.appendingPathComponent("synthetic-fixture.json"))
            let value = try JSONSerialization.jsonObject(with: manifest) as! [String: Any]
            guard value["profile"] as? String == profile else { fail("profile mismatch") }
        }
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: store)])
        if ["seed", "resume"].contains(args[1]) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            for w in 0..<(args[1] == "seed" ? workspaceCount : 0) {
                let name = String(format: "Scale %02d", w)
                let path = root.appendingPathComponent("Workspaces/\(name)")
                try fm.createDirectory(at: path, withIntermediateDirectories: true)
                let workspace = Workspace(name: name, primaryPath: path.path, instructions: "Synthetic benchmark seed")
                workspace.id = id(1, w)
                workspace.createdAt = epoch
                workspace.updatedAt = epoch
                context.insert(workspace)
            }
            try context.save()
            let seededTasks = try context.fetchCount(FetchDescriptor<AgentTask>())
            for t in 0..<taskCount {
                // A new context per task bounds seeding memory and avoids keeping
                // 116k live SwiftData models in the generator.
                try autoreleasepool {
                    let w = sidebarOnly ? t % workspaceCount : (t < 425 ? 0 : (t < 427 ? 1 : 2 + (t - 427) % 21))
                    if t >= seededTasks {
                        let c = ModelContext(container)
                        c.autosaveEnabled = false
                        let wid = id(1, w)
                        let workspace = try c.fetch(FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == wid })).first!
                        let title = t == 425 ? "Long thread" : (t == 426 ? "Short thread" : String(format: "Task %04d", t))
                        let goal = FixtureGoals.make(index: t, sidebarOnly: sidebarOnly)
                        let task = AgentTask(title: title, goal: goal, workspace: workspace)
                        task.id = id(2, t)
                        task.status = .completed
                        task.isDone = false
                        task.isPinned = false
                        task.createdAt = epoch
                        c.insert(task)
                        if !sidebarOnly {
                            let runCount = t < 425 ? 2 + (t < 386 ? 1 : 0) : 2 + (t - 425 < 1092 ? 1 : 0)
                            var runs: [TaskRun] = []
                            for r in 0..<runCount {
                                let run = TaskRun(task: task)
                                run.id = id(3, t * 10 + r)
                                run.status = .completed
                                run.stopReason = "completed"
                                run.exitCode = 0
                                run.startedAt = epoch.addingTimeInterval(Double(r))
                                run.completedAt = epoch.addingTimeInterval(Double(r + 1))
                                run.setOutput(String(repeating: "Synthetic completed output. ", count: 150))
                                c.insert(run)
                                runs.append(run)
                            }
                            let eventCount = t < 425 ? 35 + (t < 384 ? 1 : 0) : (t == 425 ? 30_000 : (t == 426 ? 2 : 39 + (t - 427 < 1764 ? 1 : 0)))
                            for e in 0..<eventCount {
                                let type = e % 10 == 0 ? "user.message" : (e % 10 == 1 ? "agent.response" : "tool.result")
                                let payload = "Synthetic \(t)/\(e). " + String(repeating: "benchmark text ", count: e % 10 < 2 ? 36 : 120)
                                let event = TaskEvent(task: task, type: type, payload: payload, run: runs[e % runs.count])
                                event.id = id(4, t * 100_000 + e)
                                event.timestamp = epoch.addingTimeInterval(Double(e))
                                c.insert(event)
                            }
                            for a in 0..<(13 + (t < 1575 ? 1 : 0)) {
                                let artifact = Artifact(task: task, type: "txt", path: taskFolder(root, w, t).appendingPathComponent(String(format: "file-%04d.txt", a)).path)
                                artifact.id = id(5, t * 100 + a)
                                artifact.createdAt = epoch
                                c.insert(artifact)
                            }
                        }
                        task.updatedAt = epoch.addingTimeInterval(Double(t))
                        try c.save()
                    }
                    if profile == "full" {
                        let folder = taskFolder(root, w, t)
                        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                        let count = t == 425 ? 862 : 21 + (t < 425 ? 1 : 0) + (t == 0 ? 1053 : 0)
                        for f in 0..<count {
                            let path = folder.appendingPathComponent(String(format: "file-%04d.txt", f))
                            // Sparse bodies keep physical disk use modest. They are
                            // synthetic file-list pressure, not realistic previews.
                            if fm.fileExists(atPath: path.path) { continue }
                            fm.createFile(atPath: path.path, contents: Data("Synthetic file \(t)/\(f)\n".utf8))
                            let handle = try FileHandle(forWritingTo: path)
                            try handle.truncate(atOffset: 46_080)
                            try handle.close()
                        }
                    }
                }
                if t % 100 == 0 { print("seeded \(t)/\(taskCount)") }
            }
        }
        let c = ModelContext(container)
        let counts = ["workspaces": try c.fetchCount(FetchDescriptor<Workspace>()),
            "tasks": try c.fetchCount(FetchDescriptor<AgentTask>()),
            "events": try c.fetchCount(FetchDescriptor<TaskEvent>()),
            "runs": try c.fetchCount(FetchDescriptor<TaskRun>()),
            "artifacts": try c.fetchCount(FetchDescriptor<Artifact>())]
        let expected = ["workspaces": workspaceCount, "tasks": taskCount, "events": sidebarOnly ? 0 : 115977,
            "runs": sidebarOnly ? 0 : 5868, "artifacts": sidebarOnly ? 0 : 30110]
        guard counts == expected else { fail("fixture count mismatch \(counts) expected \(expected)") }
        var files = 0, logicalBytes: Int64 = 0, allocatedBytes: Int64 = 0
        if let enumerator = fm.enumerator(at: root.appendingPathComponent("Workspaces"), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]) {
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey])
                if values.isRegularFile == true { files += 1; logicalBytes += Int64(values.fileSize ?? 0); allocatedBytes += Int64(values.totalFileAllocatedSize ?? 0) }
            }
        }
        if ["seed", "resume"].contains(args[1]) { guard files == (profile == "full" ? 48414 : 0) else { fail("file count mismatch: \(files)") } }
        var record: [String: Any] = ["seed": seed, "profile": profile, "verified_counts": counts, "task_folder_files": files,
            "task_folder_logical_bytes": logicalBytes, "task_folder_allocated_bytes": allocatedBytes,
            "long_thread_events": sidebarOnly ? 0 : 30000, "history_workspace_tasks": sidebarOnly ? 0 : 425,
            "history_workspace_events": sidebarOnly ? 0 : 15259]
        if args[1] == "sidebar" {
            // Reuse the real descriptor and field reads from the existing sidebar
            // experiment. This is a separate process from the app measurement.
            let before = footprint()
            let start = DispatchTime.now().uptimeNanoseconds
            let tasks = try c.fetch(SidebarTaskFetch.descriptor())
            var checksum = 0
            for task in tasks {
                checksum += task.title.utf8.count + (task.workspace?.name.utf8.count ?? 0)
                _ = task.id; _ = task.status; _ = task.isPinned; _ = task.isDone; _ = task.unreadAt; _ = task.updatedAt; _ = task.originScheduleID
            }
            record["sidebar_ms"] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            record["sidebar_footprint_delta_bytes"] = footprint() - before
            record["checksum"] = checksum
            withExtendedLifetime(tasks) { print("sidebar measured") }
        }
        // Read actual persisted goals only after the sidebar timing/footprint
        // samples, preserving both the workload and its measurement boundary.
        let goals = try c.fetch(FetchDescriptor<AgentTask>()).lazy.map(\.goal)
        guard let goalBytes = FixtureGoals.uniformByteCount(goals) else { fail("fixture goals do not have one UTF-8 byte size") }
        record["goal_bytes_per_task"] = goalBytes
        try json(record, to: root.appendingPathComponent("\(args[1] == "resume" ? "seed" : args[1])-counts.json"))
        print(String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self))
    }
    static func taskFolder(_ root: URL, _ w: Int, _ t: Int) -> URL {
        root.appendingPathComponent(String(format: "Workspaces/Scale %02d/.astra/tasks/", w) + id(2, t).uuidString.prefix(8))
    }
    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        precondition(result == KERN_SUCCESS)
        return Int64(info.phys_footprint)
    }
}
