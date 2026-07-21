#!/usr/bin/env bash

set -e -o pipefail

sdkman_switch_jdk_run_usage() {
  printf 'Usage: %s <sdkman-java-identifier> -- <command> [args...]\n' \
    "${0##*/}" >&2
}

if [[ $# -lt 3 || "$2" != "--" ]]; then
  sdkman_switch_jdk_run_usage
  exit 2
fi

sdkman_switch_jdk_run_identifier="$1"
if [[ ! "$sdkman_switch_jdk_run_identifier" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
  printf 'Invalid SDKMAN Java identifier: %s\n' \
    "$sdkman_switch_jdk_run_identifier" >&2
  exit 2
fi
if [[ "$sdkman_switch_jdk_run_identifier" == "current" ]]; then
  printf 'Invalid SDKMAN Java identifier (reserved name): %s\n' \
    "$sdkman_switch_jdk_run_identifier" >&2
  exit 2
fi
shift 2

sdkman_switch_jdk_run_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sdkman_switch_jdk_run_state_helper="$sdkman_switch_jdk_run_script_dir/sdkman-current-state.sh"
if [[ ! -r "$sdkman_switch_jdk_run_state_helper" ]]; then
  printf 'SDKMAN state helper is not readable: %s\n' \
    "$sdkman_switch_jdk_run_state_helper" >&2
  exit 1
fi
# shellcheck source=sdkman-current-state.sh
source "$sdkman_switch_jdk_run_state_helper"

sdkman_switch_jdk_run_root="${SDKMAN_DIR:-${HOME:?HOME is not set}/.sdkman}"
sdkman_switch_jdk_run_init="$sdkman_switch_jdk_run_root/bin/sdkman-init.sh"
if [[ ! -r "$sdkman_switch_jdk_run_init" ]]; then
  printf 'SDKMAN init script is not readable: %s\n' \
    "$sdkman_switch_jdk_run_init" >&2
  exit 1
fi

# SDKMAN is a shell function and must be loaded into this process.
# Prevent sdkman_auto_env from applying a project file while SDKMAN initializes.
unset SDKMAN_ENV
export SDKMAN_OLD_PWD="$PWD"
# shellcheck source=/dev/null
source "$sdkman_switch_jdk_run_init"

if ! type sdk >/dev/null 2>&1; then
  printf 'SDKMAN did not define the sdk command.\n' >&2
  exit 1
fi

sdkman_switch_jdk_run_java_dir="${SDKMAN_CANDIDATES_DIR:?SDKMAN_CANDIDATES_DIR is not set}/java"
sdkman_switch_jdk_run_current="$sdkman_switch_jdk_run_java_dir/current"
sdkman_switch_jdk_run_target="$sdkman_switch_jdk_run_java_dir/$sdkman_switch_jdk_run_identifier"

if [[ ! -x "$sdkman_switch_jdk_run_target/bin/java" ]]; then
  printf 'Java is not installed or is incomplete: %s\n' \
    "$sdkman_switch_jdk_run_identifier" >&2
  exit 1
fi

sdkman_switch_jdk_install_cleanup_traps
if ! sdkman_switch_jdk_acquire_lock run-java; then
  exit 1
fi

sdkman_switch_jdk_run_default_before="$(sdkman_switch_jdk_default_state "$sdkman_switch_jdk_run_current")"
if [[ "$sdkman_switch_jdk_run_default_before" == "unsupported" ]]; then
  printf 'Refusing to continue: SDKMAN Java current is not a symlink: %s\n' \
    "$sdkman_switch_jdk_run_current" >&2
  exit 1
fi

sdkman_switch_jdk_run_use_status=0
sdkman_switch_jdk_run_owned_state=''
if [[ "$sdkman_switch_jdk_run_default_before" == link-hex:* ]]; then
  sdkman_switch_jdk_run_owned_state="$(sdkman_switch_jdk_target_state "$sdkman_switch_jdk_run_identifier")"
  if ! sdkman_switch_jdk_register_default_reconciliation \
      "$sdkman_switch_jdk_run_current" \
      "$sdkman_switch_jdk_run_default_before" \
      "$sdkman_switch_jdk_run_owned_state"; then
    exit 1
  fi
  set +e
  sdk use java "$sdkman_switch_jdk_run_identifier"
  sdkman_switch_jdk_run_use_status=$?
  set -e
else
  :
fi

set +e
sdkman_switch_jdk_finish_operation "$sdkman_switch_jdk_run_use_status"
sdkman_switch_jdk_run_finish_status=$?
set -e

if (( sdkman_switch_jdk_deferred_signal_status != 0 )); then
  exit "$sdkman_switch_jdk_run_finish_status"
fi
if (( sdkman_switch_jdk_default_reconcile_failed != 0 )) || \
   (( sdkman_switch_jdk_run_finish_status != sdkman_switch_jdk_run_use_status )); then
  exit 1
fi

if (( sdkman_switch_jdk_run_use_status != 0 )); then
  printf 'SDKMAN failed to activate Java %s (status %d); the command was not run.\n' \
    "$sdkman_switch_jdk_run_identifier" "$sdkman_switch_jdk_run_use_status" >&2
  exit "$sdkman_switch_jdk_run_use_status"
fi

if (( sdkman_switch_jdk_default_reconcile_changed != 0 )); then
  printf 'SDKMAN changed the Java default unexpectedly; it was restored and the command was not run.\n' >&2
  exit 1
fi

# Make the requested SDK deterministic even when sdk use finds an earlier,
# non-SDKMAN java entry in PATH. This also handles an originally absent default.
export JAVA_HOME="$sdkman_switch_jdk_run_target"
export PATH="$JAVA_HOME/bin:$PATH"

hash -r
sdkman_switch_jdk_run_java="$(command -v java)"
sdkman_switch_jdk_run_expected="$sdkman_switch_jdk_run_target/bin/java"
if [[ "$sdkman_switch_jdk_run_java" != "$sdkman_switch_jdk_run_expected" ]]; then
  printf 'Active java does not match the requested SDKMAN identifier.\n' >&2
  printf 'Expected: %s\nActual:   %s\n' \
    "$sdkman_switch_jdk_run_expected" "$sdkman_switch_jdk_run_java" >&2
  exit 1
fi

java -version >&2
printf 'java: %s\n' "$sdkman_switch_jdk_run_java" >&2
sdkman_switch_jdk_clear_cleanup_traps
exec "$@"
