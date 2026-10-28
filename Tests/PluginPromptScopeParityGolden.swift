// Recorded by PluginPromptScopeParityTests; do not edit by hand.
enum PluginPromptScopeParityGolden {
    static let json = #"""
{
  "gcloud-workflow" : {
    "behaviorInstructionsDigest" : [
      "GCloud Agent:1100:Read,Bash,Glob,Grep"
    ],
    "behaviorSkills" : [
      "GCloud Agent"
    ],
    "connectors" : [
      "Google Cloud|gcloud|"
    ],
    "enabledBrowserAdapters" : [

    ],
    "enabledPackageIDs" : [
      "gcloud-workflow"
    ],
    "hostControlRoutesGitHub" : false,
    "localTools" : [
      "bq — BigQuery CLI|bq|",
      "gcloud|gcloud|",
      "gsutil|gcloud|storage"
    ],
    "reachableConnectors" : [
      "Google Cloud"
    ],
    "reachableLocalTools" : [
      "bq — BigQuery CLI",
      "gcloud",
      "gsutil"
    ],
    "reachablePackageIDs" : [
      "gcloud-workflow"
    ],
    "skillEnvironmentKeys" : [
      "GCP_PROJECT"
    ]
  },
  "github-workflow" : {
    "behaviorInstructionsDigest" : [
      "GitHub Agent:5683:Read,Glob,Grep"
    ],
    "behaviorSkills" : [
      "GitHub Agent"
    ],
    "connectors" : [

    ],
    "enabledBrowserAdapters" : [

    ],
    "enabledPackageIDs" : [
      "github-workflow"
    ],
    "hostControlRoutesGitHub" : true,
    "localTools" : [

    ],
    "reachableConnectors" : [

    ],
    "reachableLocalTools" : [

    ],
    "reachablePackageIDs" : [
      "github-workflow"
    ],
    "skillEnvironmentKeys" : [

    ]
  },
  "google-drive-browser" : {
    "behaviorInstructionsDigest" : [

    ],
    "behaviorSkills" : [

    ],
    "connectors" : [

    ],
    "enabledBrowserAdapters" : [
      "googleDrive"
    ],
    "enabledPackageIDs" : [
      "google-drive-browser"
    ],
    "hostControlRoutesGitHub" : false,
    "localTools" : [

    ],
    "reachableConnectors" : [

    ],
    "reachableLocalTools" : [

    ],
    "reachablePackageIDs" : [
      "google-drive-browser"
    ],
    "skillEnvironmentKeys" : [

    ]
  },
  "google-workspace" : {
    "behaviorInstructionsDigest" : [

    ],
    "behaviorSkills" : [

    ],
    "connectors" : [

    ],
    "enabledBrowserAdapters" : [

    ],
    "enabledPackageIDs" : [
      "google-workspace"
    ],
    "hostControlRoutesGitHub" : false,
    "localTools" : [

    ],
    "reachableConnectors" : [

    ],
    "reachableLocalTools" : [

    ],
    "reachablePackageIDs" : [
      "google-workspace"
    ],
    "skillEnvironmentKeys" : [

    ]
  },
  "jira-workflow" : {
    "behaviorInstructionsDigest" : [
      "Jira Agent:5568:Read,Glob,Grep,Bash"
    ],
    "behaviorSkills" : [
      "Jira Agent"
    ],
    "connectors" : [
      "Jira|jira|https:\/\/yourcompany.atlassian.net"
    ],
    "enabledBrowserAdapters" : [

    ],
    "enabledPackageIDs" : [
      "jira-workflow"
    ],
    "hostControlRoutesGitHub" : false,
    "localTools" : [

    ],
    "reachableConnectors" : [
      "Jira"
    ],
    "reachableLocalTools" : [

    ],
    "reachablePackageIDs" : [
      "jira-workflow"
    ],
    "skillEnvironmentKeys" : [
      "JIRA_BASE_URL"
    ]
  },
  "redcap-workflow" : {
    "behaviorInstructionsDigest" : [
      "REDCap Agent:2765:Read,Bash,Glob,Grep"
    ],
    "behaviorSkills" : [
      "REDCap Agent"
    ],
    "connectors" : [
      "REDCap|redcap|https:\/\/redcap.stanford.edu\/api\/"
    ],
    "enabledBrowserAdapters" : [

    ],
    "enabledPackageIDs" : [
      "redcap-workflow"
    ],
    "hostControlRoutesGitHub" : false,
    "localTools" : [

    ],
    "reachableConnectors" : [
      "REDCap"
    ],
    "reachableLocalTools" : [

    ],
    "reachablePackageIDs" : [
      "redcap-workflow"
    ],
    "skillEnvironmentKeys" : [
      "REDCAP_API_URL"
    ]
  },
  "security-auditor" : {
    "behaviorInstructionsDigest" : [
      "Security Auditor:1490:Read,Bash,Glob,Grep"
    ],
    "behaviorSkills" : [
      "Security Auditor"
    ],
    "connectors" : [

    ],
    "enabledBrowserAdapters" : [

    ],
    "enabledPackageIDs" : [
      "security-auditor"
    ],
    "hostControlRoutesGitHub" : false,
    "localTools" : [

    ],
    "reachableConnectors" : [

    ],
    "reachableLocalTools" : [

    ],
    "reachablePackageIDs" : [
      "security-auditor"
    ],
    "skillEnvironmentKeys" : [

    ]
  },
  "stanford-apple-mail" : {
    "behaviorInstructionsDigest" : [
      "Stanford Mail via Apple Mail Agent:3386:Read,Bash,Grep"
    ],
    "behaviorSkills" : [
      "Stanford Mail via Apple Mail Agent"
    ],
    "connectors" : [

    ],
    "enabledBrowserAdapters" : [

    ],
    "enabledPackageIDs" : [
      "stanford-apple-mail"
    ],
    "hostControlRoutesGitHub" : false,
    "localTools" : [
      "stanford-apple-mail|stanford-apple-mail|"
    ],
    "reachableConnectors" : [

    ],
    "reachableLocalTools" : [
      "stanford-apple-mail"
    ],
    "reachablePackageIDs" : [
      "stanford-apple-mail"
    ],
    "skillEnvironmentKeys" : [
      "ASTRA_APPLE_MAIL_ACCOUNT"
    ]
  },
  "stanford-healthcare-graph-mail" : {
    "behaviorInstructionsDigest" : [
      "Stanford Health Care Graph Mail Agent:2106:Read,Bash,Grep"
    ],
    "behaviorSkills" : [
      "Stanford Health Care Graph Mail Agent"
    ],
    "connectors" : [

    ],
    "enabledBrowserAdapters" : [

    ],
    "enabledPackageIDs" : [
      "stanford-healthcare-graph-mail"
    ],
    "hostControlRoutesGitHub" : false,
    "localTools" : [
      "stanford-graph-mail|stanford-graph-mail|"
    ],
    "reachableConnectors" : [

    ],
    "reachableLocalTools" : [
      "stanford-graph-mail"
    ],
    "reachablePackageIDs" : [
      "stanford-healthcare-graph-mail"
    ],
    "skillEnvironmentKeys" : [
      "ASTRA_GRAPH_MAIL_ACCOUNT",
      "ASTRA_GRAPH_MAIL_TENANT"
    ]
  }
}
"""#
}
