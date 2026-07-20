---
name: commit
description: Create a git commit
---

## Context

- Current git status: !`git status`
- Current git diff (staged and unstaged changes): !`git diff HEAD`
- Current branch: !`git branch --show-current`
- Recent commits: !`git log --oneline -10`

## Your task

You MUST invoke the git-commit-co-author skill before running git commit.

First assess whether the diff clearly spans several unrelated concerns (e.g. a bug fix plus an unrelated rename plus a new doc). Treat a cohesive change that merely touches many files as one concern — bias toward NOT splitting; only flag clear, separable concerns.

- If the changes are one concern: create a single git commit. Stage and create it using a single message, calling multiple tools in one response. Do not use any other tools or send any other text besides these tool calls.
- If the diff clearly spans several unrelated concerns: ask the user whether to record one single commit or split into atomic commits (one per concern). Then create the commit(s) accordingly — for the atomic path, stage and commit each concern separately.
