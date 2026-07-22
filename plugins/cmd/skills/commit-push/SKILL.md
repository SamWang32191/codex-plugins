---
name: commit-push
description: Commit Push
---

## Context

- Current git status: !`git status`
- Current git diff (staged and unstaged changes): !`git diff HEAD`
- Current branch: !`git branch --show-current`
- Default branch: !`git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true`
- Recent commits: !`git log --oneline -10`
- Arguments received: "$ARGUMENTS"

## Your task

You MUST invoke the git-commit-co-author skill before running git commit.

Based on the above changes:

1. Assess whether the diff clearly spans several unrelated concerns (e.g. a bug fix plus an unrelated rename plus a new doc). Treat a cohesive change that merely touches many files as one concern — bias toward NOT splitting; only flag clear, separable concerns.
   - One concern: create a single commit with an appropriate message.
   - Clearly several unrelated concerns: ask the user whether to record one single commit or split into atomic commits (one per concern), then commit accordingly. If the arguments received above ask for atomic commits (or similar), skip that question and split into atomic commits (one per concern) directly.
2. Push the branch to origin. **Safety gate:** If the current branch equals the default branch, STOP before pushing and get explicit confirmation that pushing directly to the default branch is intended. If the arguments received above already confirm this, take that as the confirmation and skip the question; otherwise stop and ask first. Commit first regardless — only the push step gates on confirmation.
3. After the push succeeds, get the branch's URL on the remote with `gh browse -n -b <branch>` and give it to the user.

When no safety-gate question is needed — a non-default branch, or the arguments already confirm the default-branch push — do the commit and push tool calls in a single message, then send the branch link as your only text output. Do not use any other tools or send any other text.
