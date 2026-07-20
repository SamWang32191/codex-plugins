---
name: pr
description:  Open a PR for the current branch
disable-model-invocation: true
---

## Context

- Current git status: !`git status`
- Current branch: !`git branch --show-current`
- Default branch: !`git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true`
- Commits ahead of default: !`git log --oneline origin/HEAD..HEAD 2>/dev/null || true`

## Your task

Based on the above context:

1. If the current branch equals the default branch, abort and tell the user to switch to a feature branch first.
2. Push the branch to origin if not already pushed. **Safety gate:** If for any reason the push target is the default branch, STOP and ask user to get explicit confirmation first.
3. Create a pull request using `gh pr create`. If `.github/` contains a PR template, follow that format. Write the PR body in detailed Traditional Chinese (正體中文), clearly describing the changes, rationale, and validation performed.

You have the capability to call multiple tools in a single response. You MUST do all of the above in a single message. Do not use any other tools or do anything else. Do not send any other text or messages besides these tool calls.
