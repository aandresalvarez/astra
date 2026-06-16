import Foundation
import Testing
@testable import ASTRA

@Suite("Browser Analysis")
struct BrowserAnalysisTests {
    @Test("V2 rollout mode parses environment and preserves explicit requests")
    func v2RolloutModeParsesEnvironmentAndExplicitRequests() {
        let suiteName = "BrowserAnalysisTests.v2.default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(BrowserAnalysisV2RolloutMode.configured(defaults: defaults, environment: [:]) == .on)
        #expect(BrowserAnalysisV2RolloutMode.configured(environment: [
            BrowserAnalysisV2RolloutMode.environmentKey: "shadow"
        ]) == .shadow)
        #expect(BrowserAnalysisV2RolloutMode.configured(environment: [
            BrowserAnalysisV2RolloutMode.environmentKey: "on"
        ]) == .on)
        #expect(BrowserAnalysisV2RolloutMode.off.effectiveVersion(requested: .v2, explicit: true) == .v2)
        #expect(BrowserAnalysisV2RolloutMode.shadow.effectiveVersion(requested: .v2, explicit: false) == .v1)
        #expect(BrowserAnalysisV2RolloutMode.on.effectiveVersion(requested: .v1, explicit: false) == .v2)
    }

    @Test("Analyzer classifies valid actions and risk")
    func analyzerClassifiesActionsAndRisk() throws {
        let analysis = BrowserAnalysisBuilder.build(
            snapshot: Self.sampleSnapshot(controls: [
                Self.control(selector: "input[name=email]", tag: "input", role: "textbox", type: "email", label: "Email"),
                Self.control(selector: "input[name=password]", tag: "input", role: "textbox", type: "password", label: "Password"),
                Self.control(selector: "button[data-testid=save]", tag: "button", role: "button", label: "Save"),
                Self.control(selector: "button.danger", tag: "button", role: "button", label: "Delete account")
            ]),
            backend: "embedded WebKit",
            engine: "embedded",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )

        #expect(analysis.pageType == "login")

        let email = try #require(analysis.controls.first { $0.label == "Email" })
        #expect(email.validActions.contains(BrowserActionKind.fill))
        #expect(email.validActions.contains(BrowserActionKind.setValue))
        #expect(email.risk == BrowserRisk.normal)

        let password = try #require(analysis.controls.first { $0.label == "Password" })
        #expect(password.risk == BrowserRisk.credentialInput)
        #expect(password.requiresUserConfirmation)

        let delete = try #require(analysis.controls.first { $0.label == "Delete account" })
        #expect(delete.validActions.contains(BrowserActionKind.click))
        #expect(delete.risk == BrowserRisk.destructive)
        #expect(delete.requiresUserConfirmation)
    }

    @Test("Analyze response is compact by default and full when requested")
    func analyzeResponseCompactAndFull() {
        let controls = (0..<25).map { index in
            Self.control(selector: "button[data-testid=item-\(index)]", tag: "button", role: "button", label: "Item \(index)")
        }
        let analysis = BrowserAnalysisBuilder.build(
            snapshot: Self.sampleSnapshot(controls: controls),
            backend: "embedded WebKit",
            engine: "embedded"
        )

        let compact = analysis.responseObject(query: nil, full: false, limit: nil)
        let full = analysis.responseObject(query: nil, full: true, limit: nil)

        #expect(compact["returnedControlCount"] as? Int == 20)
        #expect(compact["omittedControlCount"] as? Int == 5)
        #expect(full["returnedControlCount"] as? Int == 25)
        #expect(full["omittedControlCount"] as? Int == 0)
    }

    @Test("V2 response adds semantic control refs without changing default response")
    func v2ResponseAddsSemanticControlRefs() throws {
        let analysis = BrowserAnalysisBuilder.build(
            snapshot: Self.sampleSnapshot(controls: [
                Self.control(selector: "button[data-testid=save]", tag: "button", role: "button", label: "Save")
            ]),
            backend: "controlled Chromium profile",
            engine: "controlled",
            accessibilitySnapshotObject: [
                "nodeCount": 1,
                "nodes": [
                    [
                        "nodeId": "1",
                        "backendDOMNodeId": "42",
                        "ignored": false,
                        "role": ["value": "button"],
                        "name": ["value": "Save"]
                    ]
                ]
            ]
        )

        let defaultResponse = analysis.responseObject(query: nil, full: false, limit: nil)
        #expect(defaultResponse["controlRefs"] == nil)

        let v2 = analysis.responseObject(query: nil, full: false, limit: nil, version: .v2)
        #expect(v2["analysisVersion"] as? String == BrowserAnalysisVersion.v2.rawValue)
        #expect(v2["visionFallbackAvailable"] as? Bool == false)

        let refs = try #require(v2["controlRefs"] as? [[String: Any]])
        let firstRef = try #require(refs.first)
        #expect(firstRef["controlID"] as? String == analysis.controls.first?.controlID)
        #expect(firstRef["source"] as? String == BrowserControlSource.accessibility.rawValue)
        #expect(firstRef["selectorFallback"] as? String == "button[data-testid=save]")

        let sourceBreakdown = try #require(v2["sourceBreakdown"] as? [String: Any])
        #expect(sourceBreakdown["accessibilityNodeCount"] as? Int == 1)
        #expect(sourceBreakdown["accessibilityMatchedControlCount"] as? Int == 1)
        let controlRefs = try #require(sourceBreakdown["controlRefs"] as? [String: Int])
        #expect(controlRefs[BrowserControlSource.accessibility.rawValue] == 1)
    }

    @Test("Control resolver prefers accessibility identity over stale selectors")
    func controlResolverPrefersAccessibilityIdentityOverStaleSelectors() throws {
        let cached = BrowserAnalysisBuilder.build(
            snapshot: Self.sampleSnapshot(controls: [
                Self.control(selector: "#old-save", tag: "button", role: "button", label: "Save")
            ]),
            backend: "controlled Chromium profile",
            engine: "controlled",
            accessibilitySnapshotObject: Self.accessibilitySnapshot(role: "button", name: "Save")
        )
        let live = BrowserAnalysisBuilder.build(
            snapshot: Self.sampleSnapshot(controls: [
                Self.control(selector: "#new-save", tag: "button", role: "button", label: "Save")
            ]),
            backend: "controlled Chromium profile",
            engine: "controlled",
            accessibilitySnapshotObject: Self.accessibilitySnapshot(role: "button", name: "Save")
        )

        let cachedControl = try #require(cached.controls.first)
        let match = try #require(BrowserControlResolver.matchingLiveControl(
            cachedControl: cachedControl,
            cachedAnalysis: cached,
            liveAnalysis: live
        ))

        #expect(match.strategy == "accessibility")
        #expect(match.usedSelectorFallback == false)
        #expect(match.control.selector == "#new-save")
        #expect(match.controlRef.source == .accessibility)
    }

    @Test("Control IDs stay stable across state-only changes")
    func stableIDsAcrossStateOnlyChanges() throws {
        let controls = [
            Self.control(selector: "input[name=email]", tag: "input", role: "textbox", type: "email", label: "Email", value: "old@example.com")
        ]
        let first = BrowserAnalysisBuilder.build(
            snapshot: Self.sampleSnapshot(
                text: "Profile form",
                focused: ["selector": "input[name=email]", "role": "textbox", "label": "Email", "value": "old@example.com"],
                controls: controls
            ),
            backend: "embedded WebKit",
            engine: "embedded"
        )
        let second = BrowserAnalysisBuilder.build(
            snapshot: Self.sampleSnapshot(
                text: "Profile form saved",
                focused: ["selector": "input[name=email]", "role": "textbox", "label": "Email", "value": "new@example.com"],
                controls: [
                    Self.control(selector: "input[name=email]", tag: "input", role: "textbox", type: "email", label: "Email", value: "new@example.com")
                ]
            ),
            backend: "embedded WebKit",
            engine: "embedded"
        )

        let firstControl = try #require(first.controls.first)
        let secondControl = try #require(second.controls.first)

        #expect(first.fingerprint.value == second.fingerprint.value)
        #expect(first.fingerprint.stateValue != second.fingerprint.stateValue)
        #expect(firstControl.controlID == secondControl.controlID)
        #expect(BrowserAnalysisBuilder.fingerprintsCompatible(first.fingerprint, second.fingerprint))
    }

    @Test("Analysis cache stores, expires by analysis TTL, and invalidates")
    func cacheStoresAndInvalidates() throws {
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let analysis = BrowserAnalysisBuilder.build(
            snapshot: Self.sampleSnapshot(controls: [Self.control(selector: "#save", tag: "button", role: "button", label: "Save")]),
            backend: "embedded WebKit",
            engine: "embedded",
            createdAt: createdAt,
            analysisID: "ana_test",
            ttlSeconds: 1
        )
        let cache = BrowserAnalysisCache()
        cache.store(analysis)

        #expect(cache.lookup("ana_test") != nil)
        #expect(analysis.isFresh(now: createdAt.addingTimeInterval(0.5)))
        #expect(!analysis.isFresh(now: createdAt.addingTimeInterval(2)))

        cache.invalidate()
        #expect(cache.lookup("ana_test") == nil)
    }

    @Test("Google Drive file controls expose open semantics and ambiguity")
    func googleDriveFileControlsExposeOpenSemanticsAndAmbiguity() throws {
        let fileLabel = "Untitled document Google Docs Located in My Drive More info (Option + Right)"
        let analysis = BrowserAnalysisBuilder.build(
            snapshot: Self.sampleSnapshot(
                url: "https://drive.google.com/drive/home",
                title: "Home - Google Drive",
                text: "Recent Untitled document",
                controls: [
                    Self.control(
                        selector: "[aria-label='Untitled document Google Docs Located in My Drive More info']",
                        tag: "div",
                        role: "gridcell",
                        label: fileLabel,
                        y: 80
                    ),
                    Self.control(
                        selector: "[aria-label='Untitled document Google Docs Located in Shared Drive More info']",
                        tag: "div",
                        role: "gridcell",
                        label: fileLabel,
                        y: 180
                    )
                ]
            ),
            backend: "embedded WebKit",
            engine: "embedded",
            createdAt: Date(timeIntervalSince1970: 1_000),
            enabledBrowserAdapters: [BrowserSiteAdapterID.googleDrive]
        )

        #expect(analysis.pageType == "googleDrive")

        let file = try #require(analysis.controls.first)
        #expect(file.primaryAction == BrowserActionKind.open)
        #expect(file.validActions.contains(BrowserActionKind.open))
        #expect(file.validActions.contains(BrowserActionKind.doubleClick))
        #expect(file.validActions.contains(BrowserActionKind.select))

        let clickOutcome = try #require(file.actionOutcomes.first { $0["action"] as? String == BrowserActionKind.click.rawValue })
        #expect(clickOutcome["semanticAction"] as? String == BrowserActionKind.select.rawValue)
        #expect(clickOutcome["expectedOutcome"] as? String == "driveFileSelected")
        #expect(clickOutcome["doesNotGuarantee"] as? String == "googleEditorOpened")

        let response = analysis.responseObject(query: "Untitled document", full: false, limit: nil)
        let ambiguity = try #require(response["ambiguity"] as? [String: Any])
        #expect(ambiguity["type"] as? String == "duplicateLabels")
        #expect(ambiguity["matchCount"] as? Int == 2)

        let v2 = analysis.responseObject(query: "Untitled document", full: false, limit: nil, version: .v2)
        let refs = try #require(v2["controlRefs"] as? [[String: Any]])
        #expect(refs.first?["source"] as? String == BrowserControlSource.adapter.rawValue)
    }

    @Test("Google Drive semantics stay disabled without browser capability")
    func googleDriveSemanticsDisabledWithoutCapability() throws {
        let fileLabel = "Untitled document Google Docs Located in My Drive More info (Option + Right)"
        let analysis = BrowserAnalysisBuilder.build(
            snapshot: Self.sampleSnapshot(
                url: "https://drive.google.com/drive/home",
                title: "Home - Google Drive",
                controls: [
                    Self.control(
                        selector: "[aria-label='Untitled document Google Docs Located in My Drive More info']",
                        tag: "div",
                        role: "gridcell",
                        label: fileLabel
                    )
                ]
            ),
            backend: "embedded WebKit",
            engine: "embedded"
        )

        #expect(analysis.pageType != "googleDrive")
        #expect(analysis.siteAdapters.isEmpty)
        #expect(!analysis.recommendations.contains { $0["action"] as? String == BrowserActionKind.googleDriveOpen.rawValue })
        let file = try #require(analysis.controls.first)
        #expect(!file.validActions.contains(BrowserActionKind.open))
        #expect(!file.actionOutcomes.contains { $0["action"] as? String == BrowserActionKind.googleDriveOpen.rawValue })
    }

    @Test("GitHub adapter adds API-first recommendations and open semantics")
    func githubAdapterAddsRecommendationsAndOpenSemantics() throws {
        let analysis = BrowserAnalysisBuilder.build(
            snapshot: Self.sampleSnapshot(
                url: "https://github.com/coral/astra/pulls",
                title: "Pull requests - coral/astra",
                text: "Pull requests Fix browser control",
                controls: [
                    Self.control(
                        selector: "a[href='/coral/astra/pull/42']",
                        tag: "a",
                        role: "link",
                        label: "Fix browser control #42",
                        href: "https://github.com/coral/astra/pull/42"
                    )
                ]
            ),
            backend: "controlled Chromium profile",
            engine: "controlled",
            enabledBrowserAdapters: [BrowserSiteAdapterID.github]
        )

        #expect(analysis.pageType == "github")
        #expect(analysis.siteAdapters.first?["id"] as? String == BrowserSiteAdapterID.github)
        #expect(analysis.recommendations.contains { $0["adapterID"] as? String == BrowserSiteAdapterID.github })

        let control = try #require(analysis.controls.first)
        #expect(control.validActions.contains(.open))
        #expect(control.primaryAction == .open)
        #expect(control.actionOutcomes.contains { $0["adapterID"] as? String == BrowserSiteAdapterID.github })

        let response = analysis.responseObject(query: "browser control", full: false, limit: nil, version: .v2)
        let refs = try #require(response["controlRefs"] as? [[String: Any]])
        #expect(refs.first?["source"] as? String == BrowserControlSource.adapter.rawValue)
    }

    @Test("Google Drive click outcome does not satisfy open goal without editor navigation")
    func googleDriveClickOutcomeDoesNotSatisfyOpenGoalWithoutNavigation() throws {
        let fileLabel = "Untitled document Google Docs Located in My Drive More info (Option + Right)"
        let analysis = BrowserAnalysisBuilder.build(
            snapshot: Self.sampleSnapshot(
                url: "https://drive.google.com/drive/home",
                title: "Home - Google Drive",
                controls: [
                    Self.control(
                        selector: "[aria-label='Untitled document Google Docs Located in My Drive More info']",
                        tag: "div",
                        role: "gridcell",
                        label: fileLabel
                    )
                ]
            ),
            backend: "embedded WebKit",
            engine: "embedded",
            enabledBrowserAdapters: [BrowserSiteAdapterID.googleDrive]
        )
        let file = try #require(analysis.controls.first)
        let before = Self.sampleSnapshot(
            url: "https://drive.google.com/drive/home",
            title: "Home - Google Drive",
            controls: []
        )
        let after = Self.sampleSnapshot(
            url: "https://drive.google.com/drive/home",
            title: "Home - Google Drive",
            focused: [
                "selector": file.selector,
                "role": file.role,
                "label": file.label
            ],
            controls: []
        )

        let outcome = BrowserActionOutcomeVerifier.outcome(
            action: .click,
            control: file,
            result: ["ok": true, "clicked": true],
            before: before,
            after: after,
            enabledBrowserAdapters: [BrowserSiteAdapterID.googleDrive]
        )

        #expect(outcome["executed"] as? Bool == true)
        #expect(outcome["expectedOutcome"] as? String == "driveFileSelected")
        #expect(outcome["observedOutcome"] as? String == "selectedOrFocused")
        #expect(outcome["goalSatisfied"] as? Bool == false)
        let suggestions = try #require(outcome["suggestedNextActions"] as? [[String: Any]])
        #expect(suggestions.contains { $0["action"] as? String == BrowserActionKind.googleDriveOpen.rawValue })
    }

    @Test("Google Drive open outcome is satisfied when an editor opens")
    func googleDriveOpenOutcomeSatisfiedWhenEditorOpens() throws {
        let fileLabel = "Untitled document Google Docs Located in My Drive More info (Option + Right)"
        let analysis = BrowserAnalysisBuilder.build(
            snapshot: Self.sampleSnapshot(
                url: "https://drive.google.com/drive/home",
                title: "Home - Google Drive",
                controls: [
                    Self.control(
                        selector: "[aria-label='Untitled document Google Docs Located in My Drive More info']",
                        tag: "div",
                        role: "gridcell",
                        label: fileLabel
                    )
                ]
            ),
            backend: "embedded WebKit",
            engine: "embedded",
            enabledBrowserAdapters: [BrowserSiteAdapterID.googleDrive]
        )
        let file = try #require(analysis.controls.first)

        let outcome = BrowserActionOutcomeVerifier.outcome(
            action: .doubleClick,
            control: file,
            result: ["ok": true, "clicked": true],
            before: Self.sampleSnapshot(
                url: "https://drive.google.com/drive/home",
                title: "Home - Google Drive",
                controls: []
            ),
            after: Self.sampleSnapshot(
                url: "https://docs.google.com/document/d/abc123/edit",
                title: "Untitled document - Google Docs",
                controls: []
            ),
            enabledBrowserAdapters: [BrowserSiteAdapterID.googleDrive]
        )

        #expect(outcome["expectedOutcome"] as? String == "googleEditorOpened")
        #expect(outcome["observedOutcome"] as? String == "googleEditorOpened")
        #expect(outcome["goalSatisfied"] as? Bool == true)
    }

    @Test("Outcome verifier treats page text changes as verified page changes")
    func outcomeVerifierTreatsTextChangesAsPageChanges() {
        let outcome = BrowserActionOutcomeVerifier.outcome(
            action: .click,
            control: nil,
            result: ["ok": true],
            before: Self.sampleSnapshot(text: "Before", controls: []),
            after: Self.sampleSnapshot(text: "After", controls: [])
        )

        #expect(outcome["observedOutcome"] as? String == "pageChanged")
        #expect(outcome["goalSatisfied"] as? Bool == true)
        #expect(outcome["textChanged"] as? Bool == true)
        #expect(outcome["meaningfulTextChanged"] as? Bool == true)
    }

    @Test("Outcome verifier treats failed CDP settlement as unsuccessful execution evidence")
    func outcomeVerifierTreatsFailedCDPSettlementAsUnsuccessfulExecutionEvidence() {
        let outcome = BrowserActionOutcomeVerifier.outcome(
            action: .click,
            control: nil,
            result: [
                "ok": true,
                "cdpSettlement": [
                    "settled": false,
                    "signals": ["metadata.stable"],
                    "errors": ["runtime.exception"]
                ]
            ],
            before: Self.sampleSnapshot(text: "Before", controls: []),
            after: Self.sampleSnapshot(text: "After", controls: [])
        )

        #expect(outcome["executed"] as? Bool == true)
        #expect(outcome["goalSatisfied"] as? Bool == false)
        #expect(outcome["outcomeVerified"] as? Bool == true)
        #expect(outcome["observedOutcome"] as? String == "browserActionFailed")
        #expect(outcome["outcomeReason"] as? String == "The controlled browser reported a CDP settlement failure: runtime.exception.")
    }

    @Test("Outcome verifier detects text changes from empty snapshots")
    func outcomeVerifierDetectsTextChangesFromEmptySnapshots() {
        let outcome = BrowserActionOutcomeVerifier.outcome(
            action: .click,
            control: nil,
            result: ["ok": true],
            before: Self.sampleSnapshot(text: "", controls: []),
            after: Self.sampleSnapshot(text: "Loaded document text", controls: [])
        )

        #expect(outcome["observedOutcome"] as? String == "pageChanged")
        #expect(outcome["goalSatisfied"] as? Bool == true)
        #expect(outcome["textChanged"] as? Bool == true)
        #expect(outcome["meaningfulTextChanged"] as? Bool == true)
        #expect(outcome["beforeTextHash"] as? String != "")
    }

    @Test("Outcome verifier ignores browser accessory text changes")
    func outcomeVerifierIgnoresBrowserAccessoryTextChanges() {
        let outcome = BrowserActionOutcomeVerifier.outcome(
            action: .click,
            control: Self.browserControl(
                selector: "#save-primary",
                tag: "button",
                role: "button",
                label: "Save Project"
            ),
            result: ["ok": true, "clicked": true],
            before: Self.sampleSnapshot(text: "Settings\nSave Project", controls: []),
            after: Self.sampleSnapshot(
                text: "Settings\nSave Project\n1Password menu is available. Press down arrow to select.",
                focused: [
                    "selector": "#save-primary",
                    "label": "Save Project"
                ],
                controls: []
            )
        )

        #expect(outcome["observedOutcome"] as? String == "selectedOrFocused")
        #expect(outcome["goalSatisfied"] as? Bool == false)
        #expect(outcome["textChanged"] as? Bool == true)
        #expect(outcome["meaningfulTextChanged"] as? Bool == false)
    }

    private static func sampleSnapshot(
        url: String = "https://example.com/settings",
        title: String = "Settings",
        text: String = "Settings form",
        focused: [String: Any]? = nil,
        controls: [[String: Any]]
    ) -> [String: Any] {
        [
            "ok": true,
            "url": url,
            "title": title,
            "viewport": ["width": 1440, "height": 900, "deviceScaleFactor": 2],
            "focusedElement": focused as Any,
            "text": text,
            "controls": controls
        ]
    }

    private static func accessibilitySnapshot(role: String, name: String) -> [String: Any] {
        [
            "nodeCount": 1,
            "nodes": [
                [
                    "nodeId": "1",
                    "backendDOMNodeId": "42",
                    "ignored": false,
                    "role": ["value": role],
                    "name": ["value": name]
                ]
            ]
        ]
    }

    private static func control(
        selector: String,
        tag: String,
        role: String,
        type: String = "",
        label: String,
        value: String = "",
        disabled: Bool = false,
        href: String = "",
        y: Int = 20
    ) -> [String: Any] {
        [
            "selector": selector,
            "tag": tag,
            "role": role,
            "type": type,
            "label": label,
            "name": label,
            "placeholder": "",
            "testID": "",
            "disabled": disabled,
            "actionable": !disabled,
            "value": value,
            "href": href,
            "bounds": [
                "x": 10,
                "y": y,
                "width": 120,
                "height": 32,
                "centerX": 70,
                "centerY": y + 16
            ]
        ]
    }

    private static func browserControl(
        selector: String,
        tag: String,
        role: String,
        label: String
    ) -> BrowserControl {
        BrowserControl(
            controlID: "ctl_test",
            identityHash: "hash_test",
            selector: selector,
            label: label,
            name: label,
            role: role,
            tag: tag,
            type: "",
            placeholder: "",
            testID: "",
            value: "",
            href: "",
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
            validActions: [.click],
            primaryAction: .click,
            actionOutcomes: [
                [
                    "action": BrowserActionKind.click.rawValue,
                    "semanticAction": "click",
                    "expectedOutcome": "activation"
                ]
            ],
            risk: .normal,
            confidence: 0.99,
            rank: 100,
            evidence: [:]
        )
    }
}
