---
name: sdkman-switch-jdk
description: Temporarily switch the current shell to a locally installed JDK with SDKMAN. Use for Java version mismatches or when Maven, Gradle, tests, or other local commands require a specific JDK.
---

# Temporarily Switch JDK

Use the local SDKMAN installation and `sdk use java`. Keep the change scoped to the shell that runs the command.

## Workflow

1. Determine the required JDK from the user request or project configuration. Prefer an explicit user choice.
2. If the exact identifier is unknown, list only locally installed JDKs:

```bash
find "${SDKMAN_DIR:-$HOME/.sdkman}/candidates/java" \
  -mindepth 1 -maxdepth 1 ! -name current -exec basename {} \; | sort
```

3. Load SDKMAN, switch, verify, and run the requested command in the same non-login shell:

```bash
bash -c '
  source "${SDKMAN_DIR:-$HOME/.sdkman}/bin/sdkman-init.sh" &&
  sdk use java <identifier> &&
  java -version &&
  command -v java &&
  <actual-command>
'
```

Tool calls may start fresh shells, so keep `source`, `sdk use`, and the requested command in one call. If SDKMAN is unavailable or `sdk use` reports that the identifier is not installed, report the missing item and stop.

Report the selected identifier, `java -version`, Java path, and requested command result.

## Scope

Keep the switch temporary with `sdk use`. Install a JDK, run `sdk default`, or modify `.sdkmanrc` only when explicitly requested.
