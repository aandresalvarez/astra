import Foundation
import Testing
@testable import ASTRA

@Suite("Brokered skill instruction lint")
@MainActor
struct BrokeredSkillInstructionLintTests {
    /// Verbatim shape of the instruction that produced the incident: the skill
    /// told the agent to authenticate to Jira itself.
    @Test("Instructions naming a brokered credential are flagged with the broker route")
    func instructionsNamingABrokeredCredentialAreFlagged() {
        let findings = BrokeredSkillInstructionLint.findings(
            instructions: """
            Use Basic auth with $JIRA_EMAIL and $JIRA_API_TOKEN to read the attestation ticket, \
            then export the study fields with REDCAP_API_TOKEN.
            """
        )

        #expect(findings.map(\.environmentKey) == ["JIRA_EMAIL", "JIRA_API_TOKEN", "REDCAP_API_TOKEN"])
        #expect(findings.allSatisfy { $0.source == .instructions })
        #expect(findings.first?.route == "mcp__astra_host__jira")
        #expect(findings.last?.route == "mcp__astra_host__redcap")
        #expect(findings.first?.message.contains("mcp__astra_host__jira") == true)
    }

    @Test("A namespaced brokered key resolves to its service")
    func namespacedBrokeredKeyResolvesToItsService() {
        let findings = BrokeredSkillInstructionLint.findings(
            instructions: "Read REDCAP_STUDY_A_SOURCE_API_TOKEN before exporting."
        )

        #expect(findings.count == 1)
        #expect(findings.first?.serviceType == "redcap")
        #expect(findings.first?.toolName == "redcap")
    }

    @Test("A skill declaring a brokered credential as its own parameter is flagged")
    func skillDeclaringABrokeredCredentialParameterIsFlagged() {
        let findings = BrokeredSkillInstructionLint.findings(
            instructions: "Check the attestation status.",
            environmentKeys: ["JIRA_API_TOKEN", "ATTESTATION_SHEET_ID"]
        )

        #expect(findings.map(\.environmentKey) == ["JIRA_API_TOKEN"])
        #expect(findings.first?.source == .environmentKey)
    }

    /// The lint has to stay quiet on everything it does not own, or authors
    /// learn to ignore it.
    @Test("Prose, unbrokered variables, and duplicates do not raise findings")
    func proseAndUnbrokeredVariablesDoNotRaiseFindings() {
        #expect(BrokeredSkillInstructionLint.findings(
            instructions: "File a Jira ticket and record the REDCap project name."
        ).isEmpty)
        #expect(BrokeredSkillInstructionLint.findings(
            instructions: "Read $PORTAL_API_TOKEN and $OPENAI_API_KEY."
        ).isEmpty)

        let duplicates = BrokeredSkillInstructionLint.findings(
            instructions: "Use JIRA_API_TOKEN, and if that fails use JIRA_API_TOKEN again.",
            environmentKeys: ["JIRA_API_TOKEN"]
        )
        #expect(duplicates.count == 2)
        #expect(duplicates.map(\.source) == [.instructions, .environmentKey])
    }

    /// Verbatim from `Astra/Resources/Capabilities/redcap-workflow.json`. The
    /// shipped skill names the variable in order to forbid it, which is the
    /// instruction this lint is trying to produce - flagging it would train
    /// authors to dismiss the warning.
    @Test("A prohibition that names the credential is not a finding")
    func prohibitionNamingTheCredentialIsNotAFinding() {
        #expect(BrokeredSkillInstructionLint.findings(
            instructions: """
            The token is not in your environment and never will be. Do not ask for it, do not look \
            for REDCAP_API_TOKEN, and do not try to read it out of ASTRA_CONNECTORS — those values \
            are deliberately absent.
            """
        ).isEmpty)
    }

    /// `JIRA_BASE_URL` is the shipped Jira skill's own parameter. It is
    /// withheld from a brokered run like everything else the connector
    /// declares, but it is a site address, not authentication material.
    @Test("Non-credential keys for a brokered service are not findings")
    func nonCredentialKeysAreNotFindings() {
        #expect(BrokeredSkillInstructionLint.findings(
            instructions: "Link tickets using JIRA_BASE_URL and filter by JIRA_PROJECTS.",
            environmentKeys: ["JIRA_BASE_URL"]
        ).isEmpty)
    }
}
