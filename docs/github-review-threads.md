# GitHub review thread replies and resolutions

ASTRA can read PR review conversations and send approved replies and resolutions.
The GitHub host tool provides two fixed reads:

```text
review-threads --repo OWNER/REPO --pr NUMBER [--after CURSOR]
review-thread --id THREAD_ID [--after CURSOR]
```

MCP runtimes pass these tokens in the GitHub tool's `arguments` array. CLI-relay
runtimes prefix the command with `astra-host-control github --`. The returned
`pageInfo` belongs to each connection: page the thread list and then each thread's
comments until `hasNextPage` is false. A thread ID identifies the conversation;
comment IDs identify individual messages. Raw `api` calls remain unavailable
through the broker.

When asked to reply or resolve, the agent writes a proposal under the task folder:

```json
{
  "pull_request_url": "https://github.com/OWNER/REPO/pull/12",
  "commit_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "threads": [
    {
      "thread_id": "THREAD_NODE_ID",
      "expected_last_comment_id": "LATEST_COMMENT_NODE_ID",
      "reply": "Fixed in COMMIT. Validation: TEST_RESULT.",
      "resolve": true
    }
  ]
}
```

Name it `pr12_threads.json`, or use a versioned name such as
`pr12_threads_2.json` for a later batch. Omit `reply` for resolution alone; set
`resolve` to false for a reply that keeps the conversation open. Include only
addressed threads, with at most 100 unique threads per proposal. In Ask, writing
this file uses normal Write approval.

After the run, the decision dock offers **Review thread changes**. The sheet
shows the PR, head commit, current discussion, exact reply text, and resolution
choice for every thread. **Send thread changes** is the only publication action.
The agent reports the proposal as pending until ASTRA saves receipts.

## Validation and recovery

- ASTRA uses its own host GitHub CLI credentials. The provider does not need
  an authenticated native `gh` session for this workflow.
- The proposal must be a regular JSON file under the task folder. Extra fields,
  foreign targets, duplicate threads, empty replies, and oversized files fail
  validation. The filename, user request or repository origin, and live thread
  membership must agree on the PR.
- Approval binds the file, active request, head commit, and complete discussion.
  File edits, new comments, edited comments, resolution changes, and a new PR
  head invalidate that approval. Discussions are read in bounded pages.
- ASTRA saves a dispatch event before any write, then saves each confirmed reply
  and resolution. Only a complete batch receipt satisfies the task's requested
  external outcome. Receipts for new PR reviews are separate.
- If a request fails or its response is lost, the dispatched proposal cannot be
  resent. Confirmed action receipts remain available in task history. Read
  GitHub again before preparing the remaining operations in a new file; omit
  replies that already exist. GitHub's `clientMutationId` is a response
  correlation field, not an idempotency guarantee.
- Trusted local recovery retains dispatch and receipt evidence. Imported
  workspace files quarantine these event types so imported claims cannot grant
  publication authority or satisfy a new completion gate.

The app sends fixed GraphQL
[`addPullRequestReviewThreadReply` and `resolveReviewThread` mutations](https://docs.github.com/en/graphql/reference/pulls).
Agents can supply their variables through a reviewed proposal, never GraphQL
query text or a credentialed script.

Focused regression coverage:

```bash
swift test --filter 'GitHubReviewThreadWorkflowTests|GitHubReviewPublicationTests|HostControlToolSupportTests|TaskDecisionDockPresentationTests|TaskCompletionPolicyTests'
```
