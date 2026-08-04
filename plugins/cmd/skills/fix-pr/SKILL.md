---
name: fix-pr
description: Verify PR feedback, apply justified fixes, push any changes, and close review threads.
---

# Fix Pr

## Context

- Arguments received: "$ARGUMENTS"
- Current git status: !`git status --short --branch`
- Current branch: !`git branch --show-current`

## Review set

Build one review set containing:

- The chronologically newest pull request comment across issue comments, review bodies, and inline review comments.
- The newest comment in every unresolved review thread.

Deduplicate entries by GitHub node ID. Use this same review set for evaluation, publication, thread closure, and the final report.

## Gates

### 1. Input gate

1. Parse the arguments as one accessible GitHub pull request URL and resolve its owner, repository, and pull request number.
2. Resolve the pull request's head repository, head ref, head SHA, and a writable remote for that exact repository and ref.
3. Use a matching worktree that preserves unrelated local and untracked changes.

Complete this gate when the pull request identity, writable head target, head SHA, and safe worktree are all verified. Stop and request a valid URL or writable head target when either cannot be verified.

### 2. Snapshot gate

1. Fetch the current head SHA, reviews, issue comments, inline review comments, and review threads from GitHub. Use review-thread data that includes thread IDs and resolution state.
2. Build the review set from this single snapshot.
3. Refresh the local head to the snapshot SHA before evaluation.

Complete this gate when the newest pull request comment and every unresolved review thread are represented exactly once in the review set at the recorded head SHA.

### 3. Evidence gate

For every actionable claim in the review set:

1. Inspect the referenced code and repository guidance at the recorded head SHA.
2. Reproduce the claim or establish it with focused static evidence when practical.
3. Classify it as `fix`, `reject`, or `non-actionable`.
   - `fix`: the claim is correct; implement the smallest complete change.
   - `reject`: the claim is incorrect, stale, already addressed, unsupported, or outside the pull request's stated scope; preserve the code and record concise evidence.
   - `non-actionable`: the entry requests no code or documentation change; record why no change is required.
4. Split mixed feedback into separate claims and classify each one.

Complete this gate when every review-set claim has one classification and supporting evidence, and every `fix` classification has a corresponding implementation.

### 4. Validation gate

Run repository-mandated validation plus at least one focused check for each implemented `fix`. When a focused check is unavailable, record the concrete reason and the strongest available substitute.

Complete this gate when every implemented `fix` has recorded validation evidence and all required checks pass.

### 5. Publish gate

When files changed:

1. Commit only the implemented fixes using the repository's commit conventions.
2. Push with a normal fast-forward push to the verified head remote and ref.
3. Refresh the pull request and compare its head SHA with the pushed commit SHA.

Complete this gate when the pull request head SHA equals the pushed commit SHA. When no files changed, complete it with an empty task diff and no new commit.

### 6. Closure gate

Refresh the pull request head and unresolved threads before responding, then record one outcome for every review-set entry:

- For a `fix` in a thread, reply with the change, validation, and pushed commit SHA, then resolve the thread.
- For a `reject` or `non-actionable` entry, reply with the classification and evidence. Resolve the thread when the reply conclusively addresses it and resolution is available.
- For an entry outside a review thread, post the same outcome as a pull request reply.

Complete this gate when every review-set entry has a posted reply or an appropriate resolution, and every claimed fix exists on the current pull request head.

### 7. Report gate

Report the `fix`, `reject`, and `non-actionable` outcomes, validation results, pushed commit SHA when present, and final status of every targeted thread.

Complete the task only when the report accounts for every review-set entry.
