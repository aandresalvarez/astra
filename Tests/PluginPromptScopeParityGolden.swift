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
      "GitHub Agent:5733:Read,Glob,Grep"
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
  }
}
"""#
}
