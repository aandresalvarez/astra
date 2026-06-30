import Foundation
import Testing

@Suite("App Bundle Packaging")
struct AppBundlePackagingTests {
    private let swiftMailTools = [
        "astra-browser": "AstraBrowserTool",
        "astra-local-model": "AstraLocalModelTool",
        "astra-mcp-gateway": "AstraMCPGatewayTool",
        "astra-host-control": "AstraHostControlTool",
        "astra-workspace": "AstraWorkspaceTool",
        "stanford-mail": "StanfordMailTool",
        "stanford-apple-mail": "StanfordAppleMailTool",
        "stanford-graph-mail": "StanfordGraphMailTool"
    ]

    @Test("build script stages SwiftPM resources inside Contents/Resources before signing")
    func swiftPMResourcesAreStagedInSignedResourcesDirectory() throws {
        let script = try String(contentsOf: repoRoot.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)
        let resourceCopy = #"cp -R "$BUILD_DIR/ASTRA_ASTRA.bundle" "$APP_RESOURCES/""#
        let toolCopy = #"cp "$BUILD_DIR/$tool_product" "$BUNDLED_TOOLS_DIR/$tool_product""#
        let invalidRootCopy = #"cp -R "$BUILD_DIR/ASTRA_ASTRA.bundle" "$APP_BUNDLE/""#
        let signingCommand = #"/usr/bin/codesign --force --deep"#

        #expect(script.contains(resourceCopy))
        #expect(script.contains(toolCopy))
        #expect(!script.contains(invalidRootCopy))
        #expect(try index(of: resourceCopy, in: script) < index(of: signingCommand, in: script))
        #expect(try index(of: toolCopy, in: script) < index(of: signingCommand, in: script))
    }

    @Test("native local model bundle copies resources and gates cold start")
    func nativeLocalModelBundleCopiesResourcesAndGatesColdStart() throws {
        let script = try String(contentsOf: repoRoot.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)
        let releaseScript = try String(contentsOf: repoRoot.appendingPathComponent("script/release_update.sh"), encoding: .utf8)
        let resourceFind = #"find "$NATIVE_LOCAL_MODEL_BUILD_DIR" -maxdepth 1 \( -name "*.bundle" -o -name "*.metallib" \) -print"#

        #expect(script.contains(#"LOCAL_MODEL_BACKEND="${ASTRA_LOCAL_MODEL_BACKEND:-mlx}""#))
        #expect(script.contains("Production and beta ASTRA bundles must include the native MLX local model helper."))
        #expect(script.contains("The scaffold helper is only allowed for development-channel builds."))
        #expect(!script.contains("ASTRA_ALLOW_SCAFFOLD_LOCAL_MODEL_RELEASE"))
        #expect(releaseScript.contains(#"ASTRA_LOCAL_MODEL_BACKEND="${ASTRA_LOCAL_MODEL_BACKEND:-mlx}""#))
        #expect(script.contains("build_native_local_model_metallib"))
        #expect(script.contains("xcrun -sdk macosx -find metal"))
        #expect(script.contains("xcodebuild -downloadComponent MetalToolchain"))
        #expect(script.contains("default.metallib"))
        #expect(script.contains("mlx.metallib"))
        #expect(script.contains("Bundled local model helper is missing MLX Metal libraries."))
        #expect(script.contains("copy_native_local_model_resources"))
        #expect(script.contains(resourceFind))
        #expect(script.contains("ASTRA_LOCAL_MODEL_SMOKE_MODEL_DIR"))
        #expect(script.contains("ASTRA_LOCAL_MODEL_COLD_START_MAX_MS"))
        #expect(script.contains(#""$helper" --health"#))
        #expect(script.contains(#""backend":"mlx""#))
        #expect(script.contains("local-model-cold-start.json"))
        #expect(script.contains("durationMs"))
    }

    @Test("release script can require complete Local MLX GA evidence")
    func releaseScriptCanRequireCompleteLocalMLXGAEvidence() throws {
        let releaseScript = try String(contentsOf: repoRoot.appendingPathComponent("script/release_update.sh"), encoding: .utf8)

        #expect(releaseScript.contains("ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE"))
        #expect(releaseScript.contains("ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY"))
        #expect(releaseScript.contains("Local MLX GA evidence preflight passed."))
        #expect(releaseScript.contains("ASTRA_LOCAL_MLX_RELEASE_BUILD_ID"))
        #expect(releaseScript.contains("local_mlx_release_readiness.py"))
        #expect(releaseScript.contains("--require-complete"))
        #expect(releaseScript.contains("--require-clean-evidence"))
        #expect(releaseScript.contains("--require-build-id"))
        #expect(releaseScript.contains("ASTRA_LOCAL_MLX_VALIDATION_BUNDLE"))
        #expect(releaseScript.contains(#"--bundle "$ASTRA_LOCAL_MLX_VALIDATION_BUNDLE""#))
        #expect(releaseScript.contains("ASTRA_LOCAL_MLX_RELEASE_EVIDENCE"))
        #expect(releaseScript.contains("ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE"))
        #expect(releaseScript.contains("ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE"))
        #expect(releaseScript.contains("ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES"))
        #expect(releaseScript.contains("require_readable_file"))
        #expect(releaseScript.contains("Local MLX GA evidence file is not readable for"))
        #expect(releaseScript.contains("local_mlx_evidence_help"))
        #expect(releaseScript.contains("Missing Local MLX GA evidence input(s):"))
        #expect(releaseScript.contains("script/local_mlx_collect_release_evidence.sh --build-id \"$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID\" --dry-run"))
        #expect(releaseScript.contains("script/local_mlx_collect_hardware_evidence.sh --dry-run"))
        #expect(releaseScript.contains("script/local_mlx_validation_bundle.py --dry-run \\"))
        #expect(releaseScript.contains("--release-candidate /tmp/astra-local-mlx-release-evidence.json"))
        #expect(releaseScript.contains("--beta-soak /tmp/astra-local-agent-beta-soak-evidence.json"))
        #expect(releaseScript.contains("--hardware /tmp/astra-local-mlx-hardware-pro.json"))
        #expect(releaseScript.contains("--out /tmp/astra-local-mlx-validation-bundle.json"))
        #expect(releaseScript.contains("When merging existing bundles, write to a new output path first:"))
        #expect(releaseScript.contains("--bundle /tmp/astra-local-mlx-validation-bundle.json"))
        #expect(releaseScript.contains("--out /tmp/astra-local-mlx-validation-bundle-merged.json"))
        #expect(releaseScript.contains("IFS=':' read -r -a LOCAL_MLX_HARDWARE_EVIDENCE_PATHS"))
        #expect(releaseScript.contains("ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES contains an empty path."))
        #expect(releaseScript.contains(#"if [[ -n "${ASTRA_LOCAL_MLX_RELEASE_BUILD_ID:-}" ]]; then"#))
        #expect(releaseScript.contains(#"LOCAL_MLX_RELEASE_BUILD_ID="$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID""#))
        #expect(releaseScript.contains(#"LOCAL_MLX_RELEASE_BUILD_ID="${ASTRA_VERSION}+${ASTRA_BUILD}""#))
        #expect(releaseScript.contains(#"--release-candidate "$ASTRA_LOCAL_MLX_RELEASE_EVIDENCE""#))
        #expect(releaseScript.contains(#"--beta-soak "$ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE""#))
        #expect(releaseScript.contains(#"--hardware "$ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE""#))
        #expect(releaseScript.contains(#"--hardware "$evidence_path""#))
        #expect(try index(of: #"if [[ -n "${ASTRA_LOCAL_MLX_RELEASE_BUILD_ID:-}" ]]; then"#, in: releaseScript) < index(of: #"LOCAL_MLX_READINESS_ARGS=(--require-complete --require-clean-evidence --require-build-id "$LOCAL_MLX_RELEASE_BUILD_ID")"#, in: releaseScript))
        #expect(try index(of: #"if [[ "$LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY" == "1" ]]; then"#, in: releaseScript) < index(of: "require_env ASTRA_SPARKLE_PUBLIC_ED_KEY", in: releaseScript))
        #expect(try index(of: #"--bundle "$ASTRA_LOCAL_MLX_VALIDATION_BUNDLE""#, in: releaseScript) < index(of: #"--release-candidate "$ASTRA_LOCAL_MLX_RELEASE_EVIDENCE""#, in: releaseScript))
        #expect(try index(of: "local_mlx_release_readiness.py", in: releaseScript) < index(of: #"ASTRA_BUILD_CONFIGURATION=release"#, in: releaseScript))

        let pathCheckDirectory = temporaryDirectory()
        let readableReleasePlaceholder = pathCheckDirectory.appendingPathComponent("release.json")
        let readableBetaPlaceholder = pathCheckDirectory.appendingPathComponent("beta.json")
        let readableHardwarePlaceholder = pathCheckDirectory.appendingPathComponent("pro.json")
        try "{}".write(to: readableReleasePlaceholder, atomically: true, encoding: .utf8)
        try "{}".write(to: readableBetaPlaceholder, atomically: true, encoding: .utf8)
        try "{}".write(to: readableHardwarePlaceholder, atomically: true, encoding: .utf8)

        let emptyPathCheck = try runReleaseScript(environment: [
            "ASTRA_VERSION": "0.1.0",
            "ASTRA_BUILD": "1",
            "ASTRA_SPARKLE_PUBLIC_ED_KEY": "public-key",
            "ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE": "1",
            "ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY": "1",
            "ASTRA_LOCAL_MLX_RELEASE_EVIDENCE": readableReleasePlaceholder.path,
            "ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE": readableBetaPlaceholder.path,
            "ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES": "\(readableHardwarePlaceholder.path)::\(readableHardwarePlaceholder.path)"
        ])
        #expect(emptyPathCheck.status == 2)
        #expect(emptyPathCheck.output.contains("ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES contains an empty path."))

        let missingBundleFile = try runReleaseScript(environment: [
            "ASTRA_VERSION": "0.1.0",
            "ASTRA_BUILD": "1",
            "ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE": "1",
            "ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY": "1",
            "ASTRA_LOCAL_MLX_RELEASE_BUILD_ID": "astra-0.1.0+1",
            "ASTRA_LOCAL_MLX_VALIDATION_BUNDLE": "/tmp/missing-astra-local-mlx-validation-bundle.json"
        ])
        #expect(missingBundleFile.status == 2)
        #expect(missingBundleFile.output.contains("Local MLX GA evidence file is not readable for ASTRA_LOCAL_MLX_VALIDATION_BUNDLE"))
        #expect(!missingBundleFile.output.contains("Traceback"))

        let missingEvidenceInputs = try runReleaseScript(environment: [
            "ASTRA_VERSION": "0.1.0",
            "ASTRA_BUILD": "1",
            "ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE": "1",
            "ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY": "1",
            "ASTRA_LOCAL_MLX_RELEASE_BUILD_ID": "astra-0.1.0+1"
        ])
        #expect(missingEvidenceInputs.status == 2)
        #expect(missingEvidenceInputs.output.contains("Missing Local MLX GA evidence input(s):"))
        #expect(missingEvidenceInputs.output.contains("ASTRA_LOCAL_MLX_RELEASE_EVIDENCE"))
        #expect(missingEvidenceInputs.output.contains("ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE"))
        #expect(missingEvidenceInputs.output.contains("ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES or ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE"))
        #expect(missingEvidenceInputs.output.contains("ASTRA_LOCAL_MLX_VALIDATION_BUNDLE=/path/to/astra-local-mlx-validation-bundle.json"))
        #expect(missingEvidenceInputs.output.contains("script/local_mlx_collect_release_evidence.sh --build-id \"$ASTRA_LOCAL_MLX_RELEASE_BUILD_ID\" --dry-run"))
        #expect(missingEvidenceInputs.output.contains("script/local_mlx_collect_hardware_evidence.sh --dry-run"))
        #expect(missingEvidenceInputs.output.contains("script/local_mlx_validation_bundle.py --dry-run"))
        #expect(missingEvidenceInputs.output.contains("--out /tmp/astra-local-mlx-validation-bundle-merged.json"))
        #expect(releaseScript.contains(#"LOCAL_MLX_MISSING_EVIDENCE+=("ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES or ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE")"#))
        #expect(!releaseScript.contains("LOCAL_MLX_MISSING_EVIDENCE+=(ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES or ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE)"))

        let evidenceDirectory = temporaryDirectory()
        let releaseEvidence = evidenceDirectory.appendingPathComponent("release.json")
        let betaEvidence = evidenceDirectory.appendingPathComponent("beta.json")
        let lowMemoryHardware = evidenceDirectory.appendingPathComponent("hardware-8gb.json")
        let baseHardware = evidenceDirectory.appendingPathComponent("hardware-16gb.json")
        let proHardware = evidenceDirectory.appendingPathComponent("hardware-pro.json")
        let maxHardware = evidenceDirectory.appendingPathComponent("hardware-max.json")
        try completeReleaseEvidence(buildIdentifier: "astra-0.1.0+1")
            .write(to: releaseEvidence, atomically: true, encoding: .utf8)
        try completeBetaEvidence.write(to: betaEvidence, atomically: true, encoding: .utf8)
        try hardwareEvidence(memoryBytes: 8 * gib, chip: "Apple M2", outcome: "blocked_as_expected")
            .write(to: lowMemoryHardware, atomically: true, encoding: .utf8)
        try hardwareEvidence(memoryBytes: 16 * gib, chip: "Apple M2", outcome: "passed")
            .write(to: baseHardware, atomically: true, encoding: .utf8)
        try hardwareEvidence(memoryBytes: 32 * gib, chip: "Apple M2 Pro", outcome: "passed")
            .write(to: proHardware, atomically: true, encoding: .utf8)
        try hardwareEvidence(memoryBytes: 64 * gib, chip: "Apple M2 Max", outcome: "passed")
            .write(to: maxHardware, atomically: true, encoding: .utf8)

        let incompleteBetaEvidence = evidenceDirectory.appendingPathComponent("beta-read-only-only.json")
        try readOnlyOnlyBetaEvidence.write(to: incompleteBetaEvidence, atomically: true, encoding: .utf8)

        let missingBetaPreflight = try runReleaseScript(environment: [
            "ASTRA_VERSION": "0.1.0",
            "ASTRA_BUILD": "1",
            "ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE": "1",
            "ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY": "1",
            "ASTRA_LOCAL_MLX_RELEASE_BUILD_ID": "astra-0.1.0+1",
            "ASTRA_LOCAL_MLX_RELEASE_EVIDENCE": releaseEvidence.path,
            "ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE": incompleteBetaEvidence.path,
            "ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES": [
                lowMemoryHardware.path,
                baseHardware.path,
                proHardware.path,
                maxHardware.path
            ].joined(separator: ":")
        ])
        #expect(missingBetaPreflight.status == 1)
        #expect(missingBetaPreflight.output.contains("Gate C Local Agent beta: in_progress"))
        #expect(missingBetaPreflight.output.contains("Gate D General availability: in_progress"))
        #expect(missingBetaPreflight.output.contains("Next beta collection:"))
        #expect(!missingBetaPreflight.output.contains("Local MLX GA evidence preflight passed."))

        let successfulPreflight = try runReleaseScript(environment: [
            "ASTRA_VERSION": "0.1.0",
            "ASTRA_BUILD": "1",
            "ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE": "1",
            "ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY": "1",
            "ASTRA_LOCAL_MLX_RELEASE_BUILD_ID": "astra-0.1.0+1",
            "ASTRA_LOCAL_MLX_RELEASE_EVIDENCE": releaseEvidence.path,
            "ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE": betaEvidence.path,
            "ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES": [
                lowMemoryHardware.path,
                baseHardware.path,
                proHardware.path,
                maxHardware.path
            ].joined(separator: ":")
        ])
        #expect(successfulPreflight.status == 0)
        #expect(successfulPreflight.output.contains("Gate D General availability: passed"))
        #expect(successfulPreflight.output.contains("Missing hardware tiers:\n  - none"))
        #expect(successfulPreflight.output.contains("Local MLX GA evidence preflight passed."))

        let dirtyReleaseEvidence = evidenceDirectory.appendingPathComponent("release-with-stale-model.json")
        try """
        {
          "schemaVersion": 1,
          "exportedAt": "2026-05-29T00:00:00Z",
          "samples": [
            \(releaseSample(mode: "local_chat", marker: "ASTRA_E2E_TEXT_OK", buildIdentifier: "astra-0.1.0+1")),
            \(releaseSample(mode: "local_agent_read_only", marker: "ASTRA_LOCAL_AGENT_READ_ONLY_OK", buildIdentifier: "astra-0.1.0+1")),
            \(releaseSample(mode: "local_chat", marker: "ASTRA_E2E_TEXT_OK", buildIdentifier: "astra-0.1.0+1", model: "Qwen/Qwen3-8B-MLX-4bit"))
          ]
        }
        """.write(to: dirtyReleaseEvidence, atomically: true, encoding: .utf8)
        let dirtyEvidencePreflight = try runReleaseScript(environment: [
            "ASTRA_VERSION": "0.1.0",
            "ASTRA_BUILD": "1",
            "ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE": "1",
            "ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY": "1",
            "ASTRA_LOCAL_MLX_RELEASE_BUILD_ID": "astra-0.1.0+1",
            "ASTRA_LOCAL_MLX_RELEASE_EVIDENCE": dirtyReleaseEvidence.path,
            "ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE": betaEvidence.path,
            "ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES": [
                lowMemoryHardware.path,
                baseHardware.path,
                proHardware.path,
                maxHardware.path
            ].joined(separator: ":")
        ])
        #expect(dirtyEvidencePreflight.status == 1)
        #expect(dirtyEvidencePreflight.output.contains("Gate D General availability: passed"))
        #expect(dirtyEvidencePreflight.output.contains("Non-covering release-candidate samples:"))
        #expect(dirtyEvidencePreflight.output.contains("1 sample(s) did not satisfy Gate A/B evidence rules"))
        #expect(!dirtyEvidencePreflight.output.contains("Local MLX GA evidence preflight passed."))

        let mixedHardwareEnvPreflight = try runReleaseScript(environment: [
            "ASTRA_VERSION": "0.1.0",
            "ASTRA_BUILD": "1",
            "ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE": "1",
            "ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY": "1",
            "ASTRA_LOCAL_MLX_RELEASE_BUILD_ID": "astra-0.1.0+1",
            "ASTRA_LOCAL_MLX_RELEASE_EVIDENCE": releaseEvidence.path,
            "ASTRA_LOCAL_AGENT_BETA_SOAK_EVIDENCE": betaEvidence.path,
            "ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE_FILES": [
                lowMemoryHardware.path,
                baseHardware.path,
                proHardware.path
            ].joined(separator: ":"),
            "ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE": maxHardware.path
        ])
        #expect(mixedHardwareEnvPreflight.status == 0)
        #expect(mixedHardwareEnvPreflight.output.contains("Hardware samples: 4"))
        #expect(mixedHardwareEnvPreflight.output.contains("Gate D General availability: passed"))
        #expect(mixedHardwareEnvPreflight.output.contains("Local MLX GA evidence preflight passed."))

        let validationBundle = evidenceDirectory.appendingPathComponent("validation-bundle.json")
        try combinedEvidenceBundle(
            releaseCandidateSamples: [
                releaseSample(mode: "local_chat", marker: "ASTRA_E2E_TEXT_OK", buildIdentifier: "astra-0.1.0+1"),
                releaseSample(mode: "local_agent_read_only", marker: "ASTRA_LOCAL_AGENT_READ_ONLY_OK", buildIdentifier: "astra-0.1.0+1")
            ],
            betaSoakSamples: [
                betaSample(successfulTools: ["workspace.read_file"]),
                betaSample(successfulTools: ["task.write_output","workspace.write_file","shell.exec","network.fetch","browser.click","browser.type"])
            ],
            hardwareSamples: [
                hardwareSample(memoryBytes: 8 * gib, chip: "Apple M2", outcome: "blocked_as_expected"),
                hardwareSample(memoryBytes: 16 * gib, chip: "Apple M2", outcome: "passed"),
                hardwareSample(memoryBytes: 32 * gib, chip: "Apple M2 Pro", outcome: "passed"),
                hardwareSample(memoryBytes: 64 * gib, chip: "Apple M2 Max", outcome: "passed")
            ]
        ).write(to: validationBundle, atomically: true, encoding: .utf8)

        let successfulBundlePreflight = try runReleaseScript(environment: [
            "ASTRA_VERSION": "0.1.0",
            "ASTRA_BUILD": "1",
            "ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE": "1",
            "ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY": "1",
            "ASTRA_LOCAL_MLX_RELEASE_BUILD_ID": "astra-0.1.0+1",
            "ASTRA_LOCAL_MLX_VALIDATION_BUNDLE": validationBundle.path
        ])
        #expect(successfulBundlePreflight.status == 0)
        #expect(successfulBundlePreflight.output.contains("Release-candidate samples: 2"))
        #expect(successfulBundlePreflight.output.contains("Hardware samples: 4"))
        #expect(successfulBundlePreflight.output.contains("Gate D General availability: passed"))
        #expect(successfulBundlePreflight.output.contains("Local MLX GA evidence preflight passed."))

        let explicitBuildIDCheckOnly = try runReleaseScript(environment: [
            "ASTRA_VERSION": "",
            "ASTRA_BUILD": "",
            "ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE": "1",
            "ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY": "1",
            "ASTRA_LOCAL_MLX_RELEASE_BUILD_ID": "astra-0.1.0+1",
            "ASTRA_LOCAL_MLX_VALIDATION_BUNDLE": validationBundle.path
        ])
        #expect(explicitBuildIDCheckOnly.status == 0)
        #expect(explicitBuildIDCheckOnly.output.contains("Required release build id: astra-0.1.0+1"))
        #expect(explicitBuildIDCheckOnly.output.contains("Local MLX GA evidence preflight passed."))

        let derivedBuildIDCheckOnlyNeedsVersion = try runReleaseScript(environment: [
            "ASTRA_VERSION": "",
            "ASTRA_BUILD": "",
            "ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE": "1",
            "ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY": "1",
            "ASTRA_LOCAL_MLX_VALIDATION_BUNDLE": validationBundle.path
        ])
        #expect(derivedBuildIDCheckOnlyNeedsVersion.status == 2)
        #expect(derivedBuildIDCheckOnlyNeedsVersion.output.contains("Missing required environment variable: ASTRA_VERSION"))

        let partialValidationBundle = evidenceDirectory.appendingPathComponent("partial-validation-bundle.json")
        try combinedEvidenceBundle(
            releaseCandidateSamples: [
                releaseSample(mode: "local_chat", marker: "ASTRA_E2E_TEXT_OK", buildIdentifier: "astra-0.1.0+1"),
                releaseSample(mode: "local_agent_read_only", marker: "ASTRA_LOCAL_AGENT_READ_ONLY_OK", buildIdentifier: "astra-0.1.0+1")
            ],
            betaSoakSamples: [
                betaSample(successfulTools: ["workspace.read_file"]),
                betaSample(successfulTools: ["task.write_output","workspace.write_file","shell.exec","network.fetch","browser.click","browser.type"])
            ],
            hardwareSamples: [
                hardwareSample(memoryBytes: 8 * gib, chip: "Apple M2", outcome: "blocked_as_expected"),
                hardwareSample(memoryBytes: 16 * gib, chip: "Apple M2", outcome: "passed"),
                hardwareSample(memoryBytes: 32 * gib, chip: "Apple M2 Pro", outcome: "passed")
            ]
        ).write(to: partialValidationBundle, atomically: true, encoding: .utf8)
        let mixedBundlePreflight = try runReleaseScript(environment: [
            "ASTRA_VERSION": "0.1.0",
            "ASTRA_BUILD": "1",
            "ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE": "1",
            "ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY": "1",
            "ASTRA_LOCAL_MLX_RELEASE_BUILD_ID": "astra-0.1.0+1",
            "ASTRA_LOCAL_MLX_VALIDATION_BUNDLE": partialValidationBundle.path,
            "ASTRA_LOCAL_MLX_HARDWARE_EVIDENCE": maxHardware.path
        ])
        #expect(mixedBundlePreflight.status == 0)
        #expect(mixedBundlePreflight.output.contains("Hardware samples: 4"))
        #expect(mixedBundlePreflight.output.contains("Gate D General availability: passed"))
        #expect(mixedBundlePreflight.output.contains("Local MLX GA evidence preflight passed."))

        let missingRequireCheck = try runReleaseScript(environment: [
            "ASTRA_VERSION": "0.1.0",
            "ASTRA_BUILD": "1",
            "ASTRA_SPARKLE_PUBLIC_ED_KEY": "public-key",
            "ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY": "1"
        ])
        #expect(missingRequireCheck.status == 2)
        #expect(missingRequireCheck.output.contains("ASTRA_LOCAL_MLX_GA_EVIDENCE_CHECK_ONLY requires ASTRA_REQUIRE_LOCAL_MLX_GA_EVIDENCE=1."))
    }

    @Test("build script can provision managed Google OAuth client in Info.plist")
    func buildScriptCanProvisionManagedGoogleOAuthClient() throws {
        let script = try String(contentsOf: repoRoot.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)
        let validation = #"if [[ -n "$GOOGLE_MANAGED_OAUTH_CLIENT_ID" ]] && ! validate_google_managed_oauth_client_id "$GOOGLE_MANAGED_OAUTH_CLIENT_ID"; then"#
        let plistWrite = #"<string>$GOOGLE_MANAGED_OAUTH_CLIENT_ID</string>"#

        #expect(script.contains("ASTRA_GOOGLE_MANAGED_OAUTH_CLIENT_ID"))
        #expect(script.contains("validate_google_managed_oauth_client_id()"))
        #expect(script.contains("Invalid ASTRA_GOOGLE_MANAGED_OAUTH_CLIENT_ID"))
        #expect(script.contains("<key>ASTRAGoogleOAuthClientID</key>"))
        #expect(script.contains(plistWrite))
        #expect(try index(of: validation, in: script) < index(of: plistWrite, in: script))
    }

    @Test("Host app sandbox entitlement stays disabled while runtime Seatbelt wrapping is active")
    func hostAppSandboxEntitlementStaysDisabledWhileRuntimeSeatbeltWrappingIsActive() throws {
        let entitlementsURL = repoRoot.appendingPathComponent("script/ASTRA.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        #expect(plist["com.apple.security.automation.apple-events"] as? Bool == true)
        #expect(plist["com.apple.security.app-sandbox"] == nil)

        let sandboxSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Astra/Services/Runtime/ExecutionSandbox.swift"),
            encoding: .utf8
        )
        let securityPlan = try String(
            contentsOf: repoRoot.appendingPathComponent("docs/security/host-app-sandbox-assessment.md"),
            encoding: .utf8
        )
        #expect(sandboxSource.contains("sandboxExecPath = \"/usr/bin/sandbox-exec\""))
        #expect(securityPlan.contains("Do not enable `com.apple.security.app-sandbox`"))
    }

    @Test("Bundled agent tools are compiled Swift products, not resource scripts")
    func bundledAgentToolsAreCompiledSwiftProducts() throws {
        let package = try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        let script = try String(contentsOf: repoRoot.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)
        let resourceToolsURL = repoRoot.appendingPathComponent("Astra/Resources/Tools", isDirectory: true)

        for (command, target) in swiftMailTools {
            #expect(package.contains(".executable(name: \"\(command)\", targets: [\"\(target)\"])"))
            #expect(package.contains("name: \"\(target)\""))
            if command == "astra-browser" || command == "astra-local-model" {
                #expect(package.contains("dependencies: [\"ASTRACore\"]"))
            } else if command == "astra-mcp-gateway" {
                #expect(package.contains("dependencies: [\"MCPGatewaySupport\"]"))
            } else if command == "astra-host-control" {
                #expect(package.contains("dependencies: [\"HostControlToolSupport\"]"))
            } else if command == "astra-workspace" {
                #expect(package.contains("dependencies: [\"WorkspaceToolSupport\"]"))
            } else {
                #expect(package.contains("dependencies: [\"MailToolSupport\"]"))
            }
            #expect(package.contains("path: \"Tools/\(target)\""))
            #expect(script.contains("\"\(command)\""))

            let legacyPythonScript = resourceToolsURL.appendingPathComponent(command)
            #expect(!FileManager.default.fileExists(atPath: legacyPythonScript.path))

            let swiftEntrypoint = repoRoot
                .appendingPathComponent("Tools", isDirectory: true)
                .appendingPathComponent(target, isDirectory: true)
                .appendingPathComponent("main.swift")
            #expect(FileManager.default.fileExists(atPath: swiftEntrypoint.path))

            let source = try String(contentsOf: swiftEntrypoint, encoding: .utf8)
            #expect(!source.contains("#!/usr/bin/env python3"))
        }

        let resourceToolFiles = try FileManager.default.contentsOfDirectory(atPath: resourceToolsURL.path)
        #expect(resourceToolFiles == [".gitkeep"])
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var gib: Int {
        1024 * 1024 * 1024
    }

    private func index(of needle: String, in haystack: String) throws -> String.Index {
        try #require(haystack.range(of: needle)?.lowerBound)
    }

    private func temporaryDirectory() -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-app-bundle-packaging-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func completeReleaseEvidence(buildIdentifier: String) -> String {
        """
        {
          "schemaVersion": 1,
          "exportedAt": "2026-05-29T00:00:00Z",
          "samples": [
            \(releaseSample(mode: "local_chat", marker: "ASTRA_E2E_TEXT_OK", buildIdentifier: buildIdentifier)),
            \(releaseSample(mode: "local_agent_read_only", marker: "ASTRA_LOCAL_AGENT_READ_ONLY_OK", buildIdentifier: buildIdentifier))
          ]
        }
        """
    }

    private func releaseSample(
        mode: String,
        marker: String,
        buildIdentifier: String,
        model: String = "Qwen/Qwen3-4B-MLX-4bit"
    ) -> String {
        """
        {
          "mode": "\(mode)",
          "model": "\(model)",
          "modelDirectory": "/tmp/Qwen3-4B-MLX-4bit",
          "helperPath": "/tmp/astra-local-model",
          "outcome": "passed",
          "inputTokens": 8,
          "outputTokens": 4,
          "stopReason": "complete",
          "marker": "\(marker)",
          "buildIdentifier": "\(buildIdentifier)"
        }
        """
    }

    private var completeBetaEvidence: String {
        """
        {
          "schemaVersion": 1,
          "exportedAt": "2026-05-29T00:00:00Z",
          "samples": [
            {
              "model": "Qwen/Qwen3-4B-MLX-4bit",
              "outcome": "completed",
              "successfulTools": ["workspace.read_file"]
            },
            {
              "model": "Qwen/Qwen3-4B-MLX-4bit",
              "outcome": "completed",
              "successfulTools": [
                "task.write_output",
                "workspace.write_file",
                "shell.exec",
                "network.fetch",
                "browser.click",
                "browser.type"
              ]
            }
          ]
        }
        """
    }

    private var readOnlyOnlyBetaEvidence: String {
        """
        {
          "schemaVersion": 1,
          "exportedAt": "2026-05-29T00:00:00Z",
          "samples": [
            {
              "model": "Qwen/Qwen3-4B-MLX-4bit",
              "outcome": "completed",
              "successfulTools": ["workspace.read_file"]
            }
          ]
        }
        """
    }

    private func betaSample(successfulTools: [String]) -> String {
        """
        {
          "model": "Qwen/Qwen3-4B-MLX-4bit",
          "outcome": "completed",
          "successfulTools": [\(successfulTools.map { #""\#($0)""# }.joined(separator: ","))]
        }
        """
    }

    private func hardwareEvidence(memoryBytes: Int, chip: String, outcome: String) -> String {
        """
        {
          "schemaVersion": 1,
          "exportedAt": "2026-05-29T00:00:00Z",
          "samples": [
            \(hardwareSample(memoryBytes: memoryBytes, chip: chip, outcome: outcome))
          ]
        }
        """
    }

    private func hardwareSample(memoryBytes: Int, chip: String, outcome: String) -> String {
        """
        {
          "outcome": "\(outcome)",
          "iterations": 3,
          "durationSeconds": 1,
          "profile": {
            "isAppleSilicon": true,
            "physicalMemoryBytes": \(memoryBytes),
            "cpuBrand": "\(chip)",
            "model": "Qwen/Qwen3-4B-MLX-4bit",
            "backend": "mlx",
            "inputTokens": 8,
            "outputTokens": 4,
            "durationMs": 1000,
            "firstTokenLatencyMs": 250,
            "tokensPerSecond": 8.0
          }
        }
        """
    }

    private func combinedEvidenceBundle(
        releaseCandidateSamples: [String],
        betaSoakSamples: [String],
        hardwareSamples: [String]
    ) -> String {
        """
        {
          "schemaVersion": 1,
          "exportedAt": "2026-05-29T00:00:00Z",
          "releaseCandidateSamples": [
            \(releaseCandidateSamples.joined(separator: ",\n"))
          ],
          "betaSoakSamples": [
            \(betaSoakSamples.joined(separator: ",\n"))
          ],
          "hardwareSamples": [
            \(hardwareSamples.joined(separator: ",\n"))
          ]
        }
        """
    }

    private func runReleaseScript(environment overrides: [String: String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repoRoot.appendingPathComponent("script/release_update.sh").path]
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in overrides {
            environment[key] = value
        }
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
