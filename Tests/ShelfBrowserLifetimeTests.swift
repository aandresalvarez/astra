import Foundation
import Testing
@testable import ASTRA

@Suite("Browser authority follows binding lifetime", .serialized)
@MainActor
struct ShelfBrowserLifetimeTests {
    @Test("Readiness stops immediately after cancellation or a known reservation")
    func readinessDoesNotSpinAfterCancellation() async {
        let session = ShelfBrowserSession()
        defer { session.teardown() }
        let clock = ContinuousClock()
        let start = clock.now
        let wait = Task { await session.waitForControlledBrowserReady(timeoutSeconds: 20) }
        await Task.yield()
        wait.cancel()
        #expect(await wait.value == false)
        session.controlledBrowser.reportOperationFailure(ControlledBrowserProfileLease.Failure.busy)
        #expect(await session.waitForControlledBrowserReady(timeoutSeconds: 20) == false)
        #expect(start.duration(to: clock.now) < .seconds(2))
    }

    @Test("A shared browser revokes credentials on A to B to A")
    func sharedRotation() async throws {
        let f = try BrowserOwnerFixture(registry: ShelfBrowserBridgeRegistry())
        let store = ShelfBrowserSessionStore(sessionFactory: { ShelfBrowserSession(registry: f.registry) })
        let shared = f.session(store, f.a, pinned: false)
        defer { shared.teardown() }
        let old = try await f.waitForEnvironment(f.a)
        #expect(f.session(store, f.b, pinned: false) === shared)
        let current = try await f.waitForEnvironment(f.b)
        #expect(old["ASTRA_BROWSER_TOKEN"] != current["ASTRA_BROWSER_TOKEN"])
        #expect(f.environment(f.a).isEmpty)
        #expect(try await get(current, token: old["ASTRA_BROWSER_TOKEN"]).status == 403)
        #expect(try await get(current).status == 200)
        #expect(f.session(store, f.a, pinned: false) === shared)
        let returned = try await f.waitForEnvironment(f.a)
        #expect(returned["ASTRA_BROWSER_TOKEN"] != old["ASTRA_BROWSER_TOKEN"])
        #expect(try await get(returned, token: current["ASTRA_BROWSER_TOKEN"]).status == 403)
    }

    @Test("An authenticated request queued before rebinding cannot execute for the new owner")
    func queuedRequest() async throws {
        let f = try BrowserOwnerFixture(registry: ShelfBrowserBridgeRegistry())
        let session = ShelfBrowserSession()
        defer { session.teardown() }
        session.bindToTask(f.a.id, ownerID: f.a.persistentModelID)
        let queuedRoute = session.makeBridgeRoute()
        session.bindToTask(f.b.id, ownerID: f.b.persistentModelID)
        let request = BrowserBridgeRequest(method: "GET", path: "/health", headers: [:], queryItems: [:], body: Data())
        let response = await queuedRoute(request)
        #expect(response.statusCode == 409)
        #expect(String(decoding: response.body, as: UTF8.self).contains("browser_session_changed"))
        session.bindToTask(f.a.id, ownerID: f.a.persistentModelID)
        #expect(await queuedRoute(request).statusCode == 409)
    }

    @Test("A real HTTP request holds its old session until completion while another owner continues")
    func inFlightReplacement() async throws {
        let f = try BrowserOwnerFixture(registry: ShelfBrowserBridgeRegistry())
        let store = ShelfBrowserSessionStore(sessionFactory: { ShelfBrowserSession(registry: f.registry) })
        let old = f.session(store, f.a, pinned: false)
        let gate = SuspendedBrowserCommand()
        old.bridgeCommandHandlerForTesting = { _ in
            await gate.pause()
            return .json(["owner": old.boundOwner == ShelfBrowserOwner(f.a) ? "A" : "WRONG"])
        }
        let oldEnv = try await f.waitForEnvironment(f.a)
        let request = Task { try await get(oldEnv) }
        await gate.waitForStart()
        #expect(old.inFlightBridgeRequests == 1 && !old.isEvictable)
        let next = f.session(store, f.b, pinned: false)
        defer { old.teardown(); next.teardown() }
        #expect(next !== old && next.ownershipNotice != nil)
        #expect(old.boundOwner == ShelfBrowserOwner(f.a))
        let nextEnv = try await f.waitForEnvironment(f.b)
        #expect(try await get(nextEnv).status == 200)
        #expect(try await get(nextEnv, token: oldEnv["ASTRA_BROWSER_TOKEN"]).status == 403)
        await gate.resume()
        let result = try await request.value
        #expect(result.status == 200 && result.body.contains("A"))
        #expect(old.inFlightBridgeRequests == 0 && old.bridgeEndpoint == nil)
        old.publishBridgeState() // late observation cannot resurrect retired authority
        #expect(f.environment(f.a).isEmpty)
        #expect(f.environment(f.b)["ASTRA_BROWSER_TOKEN"] == nextEnv["ASTRA_BROWSER_TOKEN"])
    }

    @Test("Queued UI work is fenced before it starts and running UI work drains")
    func queuedUIWork() async throws {
        let f = try BrowserOwnerFixture(registry: ShelfBrowserBridgeRegistry())
        let store = ShelfBrowserSessionStore(sessionFactory: { ShelfBrowserSession(registry: f.registry) })
        let old = f.session(store, f.a, pinned: false)
        var executed = false
        let work = old.enqueueOwnedOperation { executed = true }
        let next = f.session(store, f.b, pinned: false)
        defer { old.teardown(); next.teardown() }
        await work.value
        #expect(!executed && next !== old)
        #expect(old.inFlightBridgeRequests == 0)
    }

    @Test("Pin and unpin select one launch session and preserve it while the panel is hidden")
    func pinTransitions() async throws {
        let f = try BrowserOwnerFixture(registry: ShelfBrowserBridgeRegistry())
        let store = ShelfBrowserSessionStore(sessionFactory: { ShelfBrowserSession(registry: f.registry) })
        let pinned = f.session(store, f.a)
        let original = try await f.waitForEnvironment(f.a)
        let shared = f.session(store, f.a, pinned: false)
        defer { pinned.teardown(); shared.teardown() }
        let unpinned = try await f.waitForEnvironment(f.a)
        #expect(original["ASTRA_BROWSER_TOKEN"] != unpinned["ASTRA_BROWSER_TOKEN"])
        store.setPresented(false, taskID: f.a.id, pinnedToTask: false, taskOwnerID: f.a.persistentModelID)
        #expect(f.environment(f.a)["ASTRA_BROWSER_TOKEN"] == unpinned["ASTRA_BROWSER_TOKEN"])
        #expect(f.session(store, f.a) === pinned)
        #expect(f.environment(f.a)["ASTRA_BROWSER_TOKEN"] == original["ASTRA_BROWSER_TOKEN"])
        shared.teardown()
        #expect(f.environment(f.a)["ASTRA_BROWSER_TOKEN"] == original["ASTRA_BROWSER_TOKEN"])
    }

    @Test("Stop revokes requests authenticated before MainActor admission and rotates the token")
    func stopRevokesQueuedAdmission() async throws {
        let f = try BrowserOwnerFixture(registry: ShelfBrowserBridgeRegistry())
        let store = ShelfBrowserSessionStore(sessionFactory: { ShelfBrowserSession(registry: f.registry) })
        let session = f.session(store, f.a)
        defer { session.teardown() }
        let old = try await f.waitForEnvironment(f.a)
        let queued = session.makeBridgeRoute()
        var executed = false
        session.bridgeCommandHandlerForTesting = { _ in executed = true; return .json(["ok": true]) }
        session.stopControlledBrowser()
        let request = BrowserBridgeRequest(method: "GET", path: "/health", headers: [:], queryItems: [:], body: Data())
        #expect(await queued(request).statusCode == 409)
        #expect(!executed)
        let current = try await f.waitForEnvironment(f.a)
        #expect(current["ASTRA_BROWSER_TOKEN"] != old["ASTRA_BROWSER_TOKEN"])
        #expect(try await get(current, token: old["ASTRA_BROWSER_TOKEN"]).status == 403)
    }

    @Test("Stop cancels old commands before they can reopen Controlled Browser")
    func cancelledCommandDoesNotRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = ControlledBrowserController(profilePath: root.path)
        let session = ShelfBrowserSession()
        defer { session.teardown() }
        let gate = SuspendedBrowserCommand()
        var sawCancellation = false
        session.bridgeCommandHandlerForTesting = { _ in
            await gate.pause()
            sawCancellation = Task.isCancelled
            await controller.launch(initialAddress: "http://127.0.0.1:1")
            return .json(["cancelled": sawCancellation])
        }
        let route = session.makeBridgeRoute()
        let request = Task { await route(BrowserBridgeRequest(method: "GET", path: "/health", headers: [:], queryItems: [:], body: Data())) }
        await gate.waitForStart()
        session.stopControlledBrowser()
        await gate.resume()
        _ = await request.value
        #expect(sawCancellation)
        #expect(controller.processID == nil && controller.runState == .idle)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    private func get(_ environment: [String: String], token: String? = nil) async throws -> (status: Int, body: String) {
        let base = try #require(environment["ASTRA_BROWSER_URL"])
        var request = URLRequest(url: try #require(URL(string: base + "/health")))
        request.timeoutInterval = 5
        request.setValue(token ?? environment["ASTRA_BROWSER_TOKEN"], forHTTPHeaderField: "X-ASTRA-Browser-Token")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (try #require((response as? HTTPURLResponse)?.statusCode), String(decoding: data, as: UTF8.self))
    }
}

private actor SuspendedBrowserCommand {
    var continuation: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { continuation = $0; started?.resume(); started = nil }
    }
    func waitForStart() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil }
}
