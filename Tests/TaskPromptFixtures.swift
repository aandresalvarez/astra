enum TaskPromptFixtures {
    static let scaffoldedZipStatusGoal = """
    Recent tasks in this workspace (for context):
    - [completed] list the folders in n:/home/jupyter/users/example_user: Here are the contents of `/home/jupyter/users/example_user/deid-analysis`:
    | Name | Type |
    |------|------|
    | `README.md` | file |

    Remote Server: This workspace is connected to a remote server via SSH.
    - Name: example-workbench
    - Connect with: ssh example-workbench

    Task Output Folder: /Users/example/Documents/AgentFlow/Workspaces/example/tasks/945FF2B6
    Save any output files, reports, or artifacts to this folder. The workspace root is available for reading shared files.

    Goal: SUMMARIZE THE CONTENTS OF THIS ZIP FILE

    Context/Inputs:
    Context: /Users/example/Downloads/privacy.zip
    """
}
