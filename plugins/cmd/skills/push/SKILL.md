---
name: push
description:  Push
---


## Context

- Current git status: !`git status`
- Current branch: !`git branch --show-current`
- Default branch: !`git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true`
- Recent commits: !`git log --oneline -10`
- Unpushed commits: !`git log @{u}..HEAD --oneline 2>/dev/null || true`

## Your task

Push the current branch to origin.

**Safety gate:** If the current branch equals the default branch shown above, STOP before pushing and ask user to get explicit confirmation that pushing directly to the default branch is intended. Only after the user confirms, run `git push`. If the current branch is NOT the default branch, push immediately without asking.

When pushing without confirmation (non-default branch), do it in a single message. Do not use any other tools or send any other text besides the push.
