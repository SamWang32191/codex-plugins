---
name: create-branch
description:  Create a git branch
---

## Context

- Current git status: !`git status`
- Current git diff (staged and unstaged changes): !`git diff HEAD`
- Current branch: !`git branch --show-current`
- Recent commits: !`git log --oneline -10`

## Your task

Create a branch. Decide two things — its **name** and whether it reaches the **remote** — each turning on whether an issue is in play. **Issue in play** means `$ARGUMENTS` is an issue number/URL, or the conversation is clearly working a specific GitHub issue.

**Name.** With an issue, derive `<name>` from the issue's title/content (`gh issue view <issue> --json number,title,body` if you don't already have it). Without one, derive it from the current git state (diff, recent log). Keep `<name>` short and use only ASCII letters, digits, `-`, and `/` (e.g. `feat/42-add-handoff-commands`, `fix/null-deref`).

**Guard against duplicates.** This command isn't idempotent — run twice in a session it can stack branches. Before creating anything, once `<name>` is decided:
- **Name collision** — if `<name>` already exists locally or on the remote (`git branch --list <name>`, `git branch -r --list origin/<name>`), don't recreate it. Stop, say it exists, and offer to `git switch <name>` instead.
- **Re-run on a fresh branch** — if you're already on a non-default branch that looks freshly created with nothing committed yet (a likely leftover from a previous run), confirm the user actually wants a second branch before proceeding.

**Remote.** Take the choice from `$ARGUMENTS` if it states one; otherwise ask the user.
- With an issue — ask whether to create and link the branch on the remote. Approved: `gh issue develop <issue> --name <name> --checkout` (creates + links it on the remote). Declined: local only, `git switch -c <name>`.
- Without one — create locally with `git switch -c <name>`, then ask whether to push it. Approved: `git push -u origin <name>`. Declined: leave it local.

$ARGUMENTS
