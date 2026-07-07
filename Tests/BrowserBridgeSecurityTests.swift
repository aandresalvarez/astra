import Foundation
import Darwin
import Testing
import WebKit
@testable import ASTRA

@Suite("Browser Bridge Security")
struct BrowserBridgeSecurityTests {
    @Test("Embedded preview blocks WebKit file and media pickers")
    func embeddedPreviewBlocksWebKitFileAndMediaPickers() {
        #expect(ShelfBrowserPrivacyBoundary.blocksEmbeddedPreviewFilePickers)
        #expect(ShelfBrowserPrivacyBoundary.blocksEmbeddedPreviewMediaCapture)
    }

    @Test("Embedded preview uses an ephemeral WebKit data store")
    @MainActor
    func embeddedPreviewUsesEphemeralWebKitDataStore() {
        let configuration = ShelfBrowserWebViewConfigurationFactory.makeEmbeddedConfiguration(
            pageReadMessageHandler: NoopScriptMessageHandler()
        )

        #expect(ShelfBrowserPrivacyBoundary.usesEphemeralEmbeddedPreviewDataStore)
        #expect(!configuration.websiteDataStore.isPersistent)
    }

    @Test("Bridge requires per-session access token")
    func bridgeRequiresAccessToken() async throws {
        let endpoint = LockedEndpoint()
        let server = BrowserBridgeServer(requiredAccessToken: "session-token", route: { request in
            .json(["ok": true, "path": request.path])
        }, onEndpointChanged: { value in
            Task { await endpoint.set(value) }
        })
        server.start()
        defer { server.stop() }

        let baseURL = try await endpoint.waitForURL()
        let rejected = try await httpGet(baseURL.appendingPathComponent("health"), token: nil)
        #expect(rejected.statusCode == 403)
        #expect(rejected.body.contains("unauthorized_browser_bridge_request"))

        let accepted = try await httpGet(baseURL.appendingPathComponent("health"), token: "session-token")
        #expect(accepted.statusCode == 200)
        #expect(accepted.body.contains(#""ok" : true"#) || accepted.body.contains(#""ok":true"#))
    }

    @Test("Bridge accepts explicit token header")
    func bridgeAcceptsExplicitTokenHeader() async throws {
        let endpoint = LockedEndpoint()
        let server = BrowserBridgeServer(requiredAccessToken: "session-token", route: { request in
            .json(["ok": request.headerValue("x-astra-browser-token") == "session-token"])
        }, onEndpointChanged: { value in
            Task { await endpoint.set(value) }
        })
        server.start()
        defer { server.stop() }

        let baseURL = try await endpoint.waitForURL()
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.setValue("session-token", forHTTPHeaderField: "X-ASTRA-Browser-Token")

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = try #require((response as? HTTPURLResponse)?.statusCode)
        let body = String(data: data, encoding: .utf8) ?? ""

        #expect(statusCode == 200)
        #expect(body.contains(#""ok" : true"#) || body.contains(#""ok":true"#))
    }

    @Test("Bridge rate limiter blocks bursts and refills after the window")
    func bridgeRateLimiterBlocksBurstsAndRefills() {
        let clock = RateLimitClock(now: Date(timeIntervalSince1970: 100))
        let limiter = BrowserBridgeRateLimiter(
            maxRequests: 2,
            window: 1,
            now: { clock.now }
        )

        #expect(limiter.allowsRequest())
        #expect(limiter.allowsRequest())
        #expect(!limiter.allowsRequest())

        clock.now = Date(timeIntervalSince1970: 101.1)
        #expect(limiter.allowsRequest())
    }

    @Test("Unauthorized bridge requests do not consume the authorized request limiter")
    func unauthorizedBridgeRequestsDoNotConsumeAuthorizedLimiter() async throws {
        let endpoint = LockedEndpoint()
        let limiter = BrowserBridgeRateLimiter(maxRequests: 1, window: 60)
        let server = BrowserBridgeServer(
            requiredAccessToken: "session-token",
            rateLimiter: limiter,
            route: { _ in .json(["ok": true]) },
            onEndpointChanged: { value in
                Task { await endpoint.set(value) }
            }
        )
        server.start()
        defer { server.stop() }

        let baseURL = try await endpoint.waitForURL()
        let unauthorized = try await httpGet(baseURL.appendingPathComponent("health"), token: "wrong-token")
        #expect(unauthorized.statusCode == 403)

        let authorized = try await httpGet(baseURL.appendingPathComponent("health"), token: "session-token")
        #expect(authorized.statusCode == 200)
    }

    @Test("Bridge command contracts normalize decoded targeting fields")
    func bridgeCommandContractsNormalizeDecodedTargetingFields() throws {
        let clickJSON = Data("""
        {
          "analysisID": " analysis-1 ",
          "controlID": " control-2 ",
          "selector": " button[data-id='submit'] ",
          "label": " Submit ",
          "role": " button ",
          "placeholder": " ",
          "testID": "",
          "allowDangerous": true
        }
        """.utf8)
        let click = try JSONDecoder().decode(ClickCommand.self, from: clickJSON)

        #expect(click.normalizedSelector == "button[data-id='submit']")
        #expect(click.normalizedLabel == "Submit")
        #expect(click.normalizedRole == "button")
        #expect(click.normalizedPlaceholder == nil)
        #expect(click.normalizedTestID == nil)
        #expect(click.hasAnalysisControl)
        #expect(click.allowDangerous == true)
        #expect(BrowserDangerousActionApproval.trustedProviderApproval(click.allowDangerous) == false)

        let batchJSON = Data("""
        {
          "actions": [
            {
              "action": " CLICK ",
              "analysisID": "analysis-1",
              "controlID": " ",
              "selector": " button.primary ",
              "allowDangerous": true
            }
          ],
          "snapshotMode": "summary",
          "snapshotLimit": 12
        }
        """.utf8)
        let batch = try JSONDecoder().decode(BatchCommand.self, from: batchJSON)
        let action = try #require(batch.actions.first)

        #expect(action.normalizedAction == "click")
        #expect(action.normalizedSelector == "button.primary")
        #expect(!action.hasAnalysisControl)
        #expect(action.allowDangerous == true)
        #expect(BrowserDangerousActionApproval.trustedProviderApproval(action.allowDangerous) == false)
        #expect(batch.snapshotMode == "summary")
        #expect(batch.snapshotLimit == 12)
    }

    @Test("Bridge navigation policy rejects local file targets")
    func bridgeNavigationPolicyRejectsLocalFileTargets() {
        #expect(BrowserBridgeNavigationPolicy.normalizedProviderURL(from: "file:///etc/passwd") == nil)
        #expect(BrowserBridgeNavigationPolicy.normalizedProviderURL(from: "/etc/passwd") == nil)
        #expect(BrowserBridgeNavigationPolicy.normalizedProviderURL(from: "~/Library/Keychains/login.keychain-db") == nil)
    }

    @Test("Bridge navigation policy rejects malformed web targets without hosts")
    func bridgeNavigationPolicyRejectsMalformedWebTargets() {
        #expect(BrowserBridgeNavigationPolicy.normalizedProviderURL(from: "https:") == nil)
        #expect(BrowserBridgeNavigationPolicy.normalizedProviderURL(from: "https:///missing-host") == nil)
    }

    @Test("Bridge navigation policy allows web targets")
    func bridgeNavigationPolicyAllowsWebTargets() throws {
        let explicit = try #require(BrowserBridgeNavigationPolicy.normalizedProviderURL(
            from: "https://docs.google.com/document/d/example/edit"
        ))
        let hostname = try #require(BrowserBridgeNavigationPolicy.normalizedProviderURL(from: "outlook.office.com"))

        #expect(explicit.absoluteString == "https://docs.google.com/document/d/example/edit")
        #expect(hostname.absoluteString == "https://outlook.office.com")
    }

    @Test("Bridge open control navigation rejects unsafe hrefs before activation fallback")
    func bridgeOpenControlNavigationRejectsUnsafeHrefsBeforeFallback() throws {
        #expect(BrowserBridgeNavigationPolicy.openControlNavigation(forHref: "") == .fallbackToActivation)
        #expect(BrowserBridgeNavigationPolicy.openControlNavigation(forHref: " \n\t ") == .fallbackToActivation)
        #expect(BrowserBridgeNavigationPolicy.openControlNavigation(forHref: "file:///etc/passwd") == .reject)
        #expect(BrowserBridgeNavigationPolicy.openControlNavigation(forHref: " file:///etc/passwd ") == .reject)

        let decision = BrowserBridgeNavigationPolicy.openControlNavigation(forHref: "https://docs.google.com/document/d/example/edit")
        guard case let .navigate(url) = decision else {
            Issue.record("Expected web href to navigate, got \(decision)")
            return
        }
        #expect(url.absoluteString == "https://docs.google.com/document/d/example/edit")
    }

    @Test("Bridge open control navigation resolves relative hrefs against the page URL")
    func bridgeOpenControlNavigationResolvesRelativeHrefs() throws {
        let decision = BrowserBridgeNavigationPolicy.openControlNavigation(
            forHref: "/owner/repo/pull/159",
            pageURL: "https://github.com/owner/repo/pulls"
        )
        guard case let .navigate(url) = decision else {
            Issue.record("Expected relative web href to navigate, got \(decision)")
            return
        }
        #expect(url.absoluteString == "https://github.com/owner/repo/pull/159")
    }

    @Test("Bridge command router recognizes every published action")
    func bridgeCommandRouterRecognizesEveryPublishedAction() throws {
        let actions = ShelfBrowserBridgeCommandRouter.actionMetadata(
            canUseGoogleDriveOpen: false,
            googleDriveOpenDefaultTimeoutSeconds: 24
        )

        for action in actions {
            let method = try #require(action["method"] as? String)
            let path = try #require(action["path"] as? String)
            #expect(
                ShelfBrowserBridgeCommandRouter.route(method: method, path: path) != nil,
                "Missing route for \(method) \(path)"
            )
        }

        #expect(ShelfBrowserBridgeCommandRouter.route(method: "get", path: "/actions") == .actions)
        #expect(ShelfBrowserBridgeCommandRouter.route(method: "POST", path: "/missing") == nil)
    }

    @Test("Bridge command registry owns route specs and batch aliases")
    func bridgeCommandRegistryOwnsRouteSpecsAndBatchAliases() throws {
        let commands = ShelfBrowserBridgeCommandRouter.registeredCommands
        let registeredRoutes = commands.map(\.route)

        #expect(commands.count == ShelfBrowserBridgeRoute.allCases.count)
        for route in ShelfBrowserBridgeRoute.allCases {
            #expect(
                registeredRoutes.filter { $0 == route }.count == 1,
                "Expected one command spec for \(route)"
            )
        }

        for command in commands {
            #expect(
                ShelfBrowserBridgeCommandRouter.route(method: command.method, path: command.path) == command.route,
                "Registry route lookup should recognize \(command.method) \(command.path)"
            )
        }

        #expect(ShelfBrowserBridgeCommandRouter.route(batchAction: "double-click") == .doubleClick)
        #expect(ShelfBrowserBridgeCommandRouter.route(batchAction: "set-value") == .setValue)
        #expect(ShelfBrowserBridgeCommandRouter.route(batchAction: "google-docs-read") == .googleDocsReadDocument)
        #expect(ShelfBrowserBridgeCommandRouter.route(batchAction: "google-docs-read-visible") == .googleDocsReadVisiblePage)
        #expect(ShelfBrowserBridgeCommandRouter.route(batchAction: "drive-open") == .googleDriveOpen)
        #expect(ShelfBrowserBridgeCommandRouter.route(batchAction: "wait-selector") == .waitForSelector)
        #expect(ShelfBrowserBridgeCommandRouter.route(batchAction: "unknown") == nil)
    }

    @Test("Batch request factory covers every registered batch alias")
    func batchRequestFactoryCoversEveryRegisteredBatchAlias() {
        let aliasedRoutes = Set(ShelfBrowserBridgeCommandRouter.registeredCommands
            .filter { !$0.batchAliases.isEmpty }
            .map(\.route))

        #expect(ShelfBrowserBridgeBatchRequestFactory.supportedRoutes == aliasedRoutes)
        for route in aliasedRoutes {
            #expect(ShelfBrowserBridgeCommandRouter.command(for: route) != nil)
        }
    }

    @Test("Batch request factory delegates actions through normal bridge requests")
    func batchRequestFactoryDelegatesActionsThroughNormalBridgeRequests() throws {
        let setValueAction = try JSONDecoder().decode(BatchActionCommand.self, from: bridgeBody([
            "action": "set-value",
            "selector": " input[name=email] ",
            "text": "hello@example.com",
            "clear": false
        ]))
        let setValueConversion = try ShelfBrowserBridgeBatchRequestFactory.makeRequest(
            route: .setValue,
            action: setValueAction
        )
        guard case .request(let setValueRequest) = setValueConversion else {
            Issue.record("Expected set-value to produce a bridge request")
            return
        }

        #expect(setValueRequest.method == "POST")
        #expect(setValueRequest.path == "/setValue")
        let setValueBody = try requestBodyObject(setValueRequest)
        #expect(setValueBody["selector"] as? String == "input[name=email]")
        #expect(setValueBody["text"] as? String == "hello@example.com")
        #expect(setValueBody["clear"] as? Bool == true)

        let snapshotAction = try JSONDecoder().decode(BatchActionCommand.self, from: bridgeBody([
            "action": "snapshot",
            "mode": "not-a-mode",
            "query": "Save"
        ]))
        let snapshotConversion = try ShelfBrowserBridgeBatchRequestFactory.makeRequest(
            route: .snapshot,
            action: snapshotAction
        )
        guard case .request(let snapshotRequest) = snapshotConversion else {
            Issue.record("Expected snapshot to produce a bridge request")
            return
        }

        #expect(snapshotRequest.method == "GET")
        #expect(snapshotRequest.path == "/snapshot")
        #expect(snapshotRequest.queryItems["mode"] == "summary")
        #expect(snapshotRequest.queryItems["query"] == "Save")

        let preflightAction = try JSONDecoder().decode(BatchActionCommand.self, from: bridgeBody([
            "action": "preflight"
        ]))
        let preflightConversion = try ShelfBrowserBridgeBatchRequestFactory.makeRequest(
            route: .preflight,
            action: preflightAction
        )
        guard case .failure(let failure, let stopReason) = preflightConversion else {
            Issue.record("Expected missing preflight identifiers to produce a stopping failure")
            return
        }

        #expect(failure["error"] as? String == "missing_analysis_or_control")
        #expect(stopReason == "missing_analysis_or_control")
    }

    @Test("Verification command handler supports direct and batch execution")
    func verificationCommandHandlerSupportsDirectAndBatchExecution() async throws {
        let handler = ShelfBrowserBridgeVerificationCommandHandler(
            automationEngine: ShelfBrowserEngine.controlled,
            verifyText: { text, absent in ["ok": true, "text": text, "absent": absent] },
            waitSaved: { timeoutSeconds, intervalMilliseconds in
                ["ok": true, "timeoutSeconds": timeoutSeconds, "intervalMilliseconds": intervalMilliseconds]
            },
            waitForText: { text, timeoutSeconds, intervalMilliseconds in
                ["ok": true, "text": text, "timeoutSeconds": timeoutSeconds, "intervalMilliseconds": intervalMilliseconds]
            },
            waitForSelector: { selector, timeoutSeconds, intervalMilliseconds in
                ["ok": true, "selector": selector, "timeoutSeconds": timeoutSeconds, "intervalMilliseconds": intervalMilliseconds]
            }
        )

        #expect(handler.automationEngine.automationDescriptor.kind == .controlledCDP)
        #expect(handler.supportedRoutes == [.verifyText, .waitSaved, .waitForText, .waitForSelector])

        let directResponse = try #require(try await handler.handleDirect(
            route: .verifyText,
            request: BrowserBridgeRequest(
                method: "POST",
                path: "/verifyText",
                headers: [:],
                queryItems: [:],
                body: bridgeBody(["text": "Saved", "absent": true])
            )
        ))
        let directObject = try responseObject(directResponse)
        #expect(directObject["text"] as? String == "Saved")
        #expect(directObject["absent"] as? Bool == true)

        let batchAction = try JSONDecoder().decode(BatchActionCommand.self, from: bridgeBody([
            "action": "wait-selector",
            "selector": "input[name=q]",
            "timeoutSeconds": 2.0,
            "intervalMilliseconds": 100
        ]))
        let batchObject = try #require(try await handler.handleBatch(route: .waitForSelector, action: batchAction))
        #expect(batchObject["action"] as? String == "wait-selector")
        #expect(batchObject["selector"] as? String == "input[name=q]")
        #expect(batchObject["timeoutSeconds"] as? Double == 2.0)
        #expect(batchObject["intervalMilliseconds"] as? Int == 100)
    }

    @Test("Bridge command router centralizes request accounting policy")
    func bridgeCommandRouterCentralizesRequestAccountingPolicy() throws {
        let unaccountedRoutes: Set<ShelfBrowserBridgeRoute> = [
            .health,
            .actions,
            .trace,
            .benchmark
        ]

        for route in ShelfBrowserBridgeRoute.allCases {
            #expect(route.isFlightRecorded == !unaccountedRoutes.contains(route))
            #expect(route.isRunGuarded == !unaccountedRoutes.contains(route))
            #expect(route.isAvailableWhenBridgeDisabled == (route == .health || route == .actions))
        }
    }

    @Test("Bridge command router enforces route methods")
    func bridgeCommandRouterEnforcesRouteMethods() throws {
        #expect(ShelfBrowserBridgeCommandRouter.route(method: "POST", path: "/health") == nil)
        #expect(ShelfBrowserBridgeCommandRouter.route(method: "GET", path: "/navigate") == nil)
        #expect(ShelfBrowserBridgeCommandRouter.route(method: "GET", path: "/click") == nil)
        #expect(ShelfBrowserBridgeCommandRouter.route(method: "POST", path: "/snapshot") == nil)
    }

    @Test("GitHub browser adapter allows read routes and blocks mutating routes")
    func githubBrowserAdapterAllowsReadRoutesAndBlocksMutatingRoutes() throws {
        let enabled = Set([BrowserSiteAdapterID.github])

        #expect(BrowserSiteActionPolicy.denialReason(
            route: .snapshot,
            currentURL: "https://github.com/owner/repo/pull/1",
            enabledBrowserAdapters: enabled
        ) == nil)
        #expect(BrowserSiteActionPolicy.denialReason(
            route: .readPage,
            currentURL: "https://github.com/owner/repo/pull/1",
            enabledBrowserAdapters: enabled
        ) == nil)
        #expect(BrowserSiteActionPolicy.denialReason(
            route: .open,
            currentURL: "https://github.com/owner/repo/pull/1",
            enabledBrowserAdapters: enabled
        ) == nil)

        #expect(BrowserSiteActionPolicy.denialReason(
            route: .click,
            currentURL: "https://github.com/owner/repo/pull/1",
            enabledBrowserAdapters: enabled
        )?.contains("GitHub browser control is read-only") == true)
        #expect(BrowserSiteActionPolicy.denialReason(
            route: .fill,
            currentURL: "https://github.com/owner/repo/issues/new",
            enabledBrowserAdapters: enabled
        )?.contains("GitHub browser control is read-only") == true)
        #expect(BrowserSiteActionPolicy.denialReason(
            route: .batch,
            currentURL: "https://github.com/owner/repo/actions",
            enabledBrowserAdapters: enabled
        ) == nil)
        #expect(BrowserSiteActionPolicy.denialReason(
            route: .click,
            currentURL: "https://example.com/",
            enabledBrowserAdapters: enabled
        ) == nil)
    }

    @Test("GitHub read-only open policy allows only entity href controls")
    func githubReadOnlyOpenPolicyAllowsOnlyEntityHrefControls() throws {
        let enabled = Set([BrowserSiteAdapterID.github])
        let entity = Self.browserControl(
            label: "Pull request #159",
            href: "https://github.com/owner/repo/pull/159"
        )
        let noHref = Self.browserControl(
            label: "Pull request #159",
            href: ""
        )
        let external = Self.browserControl(
            label: "Pull request #159",
            href: "https://example.com/owner/repo/pull/159"
        )

        #expect(BrowserSiteActionPolicy.openControlDenialResult(
            action: "open",
            control: entity,
            currentURL: "https://github.com/owner/repo/pulls",
            enabledBrowserAdapters: enabled,
            githubReadOnlyMode: false
        ) == nil)
        #expect(BrowserSiteActionPolicy.openControlDenialResult(
            action: "open",
            control: noHref,
            currentURL: "https://github.com/owner/repo/pulls",
            enabledBrowserAdapters: enabled,
            githubReadOnlyMode: false
        )?["error"] as? String == "site_action_not_allowed")
        #expect(BrowserSiteActionPolicy.openControlDenialResult(
            action: "open",
            control: external,
            currentURL: "https://github.com/owner/repo/pulls",
            enabledBrowserAdapters: enabled,
            githubReadOnlyMode: false
        )?["error"] as? String == "site_action_not_allowed")
    }

    @Test("GitHub host-control read-only mode blocks mutating browser routes without adapter")
    func githubHostControlReadOnlyModeBlocksMutatingBrowserRoutesWithoutAdapter() throws {
        #expect(BrowserSiteActionPolicy.denialReason(
            route: .snapshot,
            currentURL: "https://github.com/owner/repo/pull/1",
            enabledBrowserAdapters: [],
            githubReadOnlyMode: true
        ) == nil)

        #expect(BrowserSiteActionPolicy.denialReason(
            route: .click,
            currentURL: "https://github.com/owner/repo/pull/1",
            enabledBrowserAdapters: [],
            githubReadOnlyMode: true
        )?.contains("GitHub browser control is read-only") == true)

        #expect(BrowserSiteActionPolicy.denialReason(
            route: .click,
            currentURL: "https://github.com/owner/repo/pull/1",
            enabledBrowserAdapters: [],
            githubReadOnlyMode: false
        ) == nil)
    }

    @Test("GitHub read-only mode reuses route policy for batch subactions")
    func githubReadOnlyModeReusesRoutePolicyForBatchSubactions() throws {
        for command in ShelfBrowserBridgeCommandRouter.registeredCommands where !command.batchAliases.isEmpty {
            for alias in command.batchAliases {
                let denial = BrowserSiteActionPolicy.denialReason(
                    batchAction: alias,
                    currentURL: "https://github.com/owner/repo/pull/1",
                    enabledBrowserAdapters: [],
                    githubReadOnlyMode: true
                )
                if command.route.isAllowedInGitHubReadOnlyContext {
                    #expect(denial == nil, "\(alias) should be allowed in GitHub read-only mode")
                } else {
                    #expect(
                        denial?.contains("GitHub browser control is read-only") == true,
                        "\(alias) should be blocked in GitHub read-only mode"
                    )
                }
            }
        }

        #expect(BrowserSiteActionPolicy.denialReason(
            batchAction: "click",
            currentURL: "https://example.com/",
            enabledBrowserAdapters: [],
            githubReadOnlyMode: true
        ) == nil)
    }

    @Test("Bridge actions response preserves metadata contract")
    func bridgeActionsResponsePreservesMetadataContract() throws {
        let response = ShelfBrowserBridgeCommandRouter.actionsResponse(
            backend: "controlled Chromium profile",
            automationEngine: BrowserAutomationEngineDescriptor(kind: .controlledCDP),
            capabilities: ["actions", "google.drive.open"],
            canUseGoogleDriveOpen: true,
            googleDriveOpenDefaultTimeoutSeconds: 24
        )

        #expect(response["ok"] as? Bool == true)
        #expect(response["backend"] as? String == "controlled Chromium profile")
        let engine = try #require(response["automationEngine"] as? [String: Any])
        #expect(engine["kind"] as? String == "controlled-cdp")
        #expect(engine["providerToolName"] as? String == "astra-browser")
        #expect(engine["exposesRawDebugEndpoint"] as? Bool == false)
        #expect(response["actionMetadataVersion"] as? Int == 1)
        #expect(response["capabilities"] as? [String] == ["actions", "google.drive.open"])

        let actions = try #require(response["actions"] as? [[String: Any]])
        let paths = Set(actions.compactMap { $0["path"] as? String })
        #expect(paths.contains("/actions"))
        #expect(paths.contains("/googleDriveOpen"))

        let driveOpen = try #require(actions.first { ($0["path"] as? String) == "/googleDriveOpen" })
        #expect(driveOpen["enabled"] as? Bool == true)
        #expect(driveOpen["adapterID"] as? String == BrowserSiteAdapterID.googleDrive)

        let body = try #require(driveOpen["body"] as? [String: Any])
        #expect(body["name"] as? String == "Untitled document")
        #expect(body["timeoutSeconds"] as? Double == 24)
    }

    @Test("Malformed negative Content-Length receives 400 instead of crashing parser")
    func malformedNegativeContentLengthReceivesBadRequest() async throws {
        let endpoint = LockedEndpoint()
        let server = BrowserBridgeServer(requiredAccessToken: nil, route: { _ in
            .json(["ok": true])
        }, onEndpointChanged: { value in
            Task { await endpoint.set(value) }
        })
        server.start()
        defer { server.stop() }

        let baseURL = try await endpoint.waitForURL()
        let response = try rawHTTP(
            to: baseURL,
            request: "POST /health HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: -1\r\n\r\n"
        )

        #expect(response.contains("HTTP/1.1 400 Bad Request"))
        #expect(response.contains("invalid_content_length"))
    }

    private func httpGet(_ url: URL, token: String?) async throws -> (statusCode: Int, body: String) {
        var request = URLRequest(url: url)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = try #require((response as? HTTPURLResponse)?.statusCode)
        return (statusCode, String(data: data, encoding: .utf8) ?? "")
    }

    private static func browserControl(label: String, href: String) -> BrowserControl {
        BrowserControl(
            controlID: "ctl_test",
            identityHash: "hash_test",
            selector: href.isEmpty ? "button[data-test='pull-request']" : "a[href='\(href)']",
            label: label,
            name: label,
            role: href.isEmpty ? "button" : "link",
            tag: href.isEmpty ? "button" : "a",
            type: "",
            autocomplete: "",
            placeholder: "",
            testID: "",
            value: "",
            href: href,
            framePath: [],
            shadowDepth: 0,
            disabled: false,
            visible: true,
            actionable: true,
            bounds: [
                "x": 10,
                "y": 20,
                "width": 120,
                "height": 32,
                "centerX": 70,
                "centerY": 36
            ],
            validActions: [.open],
            primaryAction: .open,
            actionOutcomes: [
                [
                    "action": BrowserActionKind.open.rawValue,
                    "semanticAction": BrowserActionKind.open.rawValue,
                    "expectedOutcome": "githubEntityOpened"
                ]
            ],
            risk: .normal,
            providerVisibleRedaction: BrowserControlProviderVisibleRedaction(
                rawControlObject: [
                    "selector": href.isEmpty ? "button[data-test='pull-request']" : "a[href='\(href)']",
                    "label": label,
                    "name": label,
                    "role": href.isEmpty ? "button" : "link",
                    "tag": href.isEmpty ? "button" : "a",
                    "type": "",
                    "placeholder": "",
                    "testID": "",
                    "value": "",
                    "href": href,
                    "autocomplete": ""
                ],
                risk: .normal
            ),
            confidence: 0.99,
            rank: 1,
            evidence: [:]
        )
    }

    private func rawHTTP(to baseURL: URL, request: String) throws -> String {
        let port = try #require(baseURL.port)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrowserBridgeSecurityTestError.socketFailed }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            throw BrowserBridgeSecurityTestError.socketFailed
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw BrowserBridgeSecurityTestError.socketFailed }

        let bytes = Array(request.utf8)
        try bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            let written = Darwin.write(fd, baseAddress, bytes.count)
            guard written == bytes.count else { throw BrowserBridgeSecurityTestError.socketFailed }
        }
        shutdown(fd, SHUT_WR)

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let readCount = Darwin.read(fd, &buffer, buffer.count)
            if readCount > 0 {
                data.append(buffer, count: readCount)
            } else {
                break
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func bridgeBody(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func responseObject(_ response: BrowserBridgeResponse) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private func requestBodyObject(_ request: BrowserBridgeRequest) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }
}

private final class NoopScriptMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
}

private actor LockedEndpoint {
    private var value: String?

    func set(_ nextValue: String?) {
        value = nextValue
    }

    func waitForURL() async throws -> URL {
        for _ in 0..<100 {
            let snapshot = value
            if let snapshot, let url = URL(string: snapshot) {
                return url
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw BrowserBridgeSecurityTestError.endpointUnavailable
    }
}

private enum BrowserBridgeSecurityTestError: Error {
    case endpointUnavailable
    case socketFailed
}

private final class RateLimitClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}
