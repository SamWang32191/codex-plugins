#!/usr/bin/env bash

set -e -o pipefail

sdkman_switch_jdk_usage() {
  printf 'Usage: %s <sdkman-java-identifier>\n' "${0##*/}" >&2
}

if [[ $# -ne 1 ]]; then
  sdkman_switch_jdk_usage
  exit 2
fi

sdkman_switch_jdk_identifier="$1"
if [[ ! "$sdkman_switch_jdk_identifier" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
  printf 'Invalid SDKMAN Java identifier: %s\n' "$sdkman_switch_jdk_identifier" >&2
  exit 2
fi
if [[ "$sdkman_switch_jdk_identifier" == "current" ]]; then
  printf 'Invalid SDKMAN Java identifier (reserved name): %s\n' \
    "$sdkman_switch_jdk_identifier" >&2
  exit 2
fi

sdkman_switch_jdk_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sdkman_switch_jdk_state_helper="$sdkman_switch_jdk_script_dir/sdkman-current-state.sh"
if [[ ! -r "$sdkman_switch_jdk_state_helper" ]]; then
  printf 'SDKMAN state helper is not readable: %s\n' \
    "$sdkman_switch_jdk_state_helper" >&2
  exit 1
fi
# shellcheck source=sdkman-current-state.sh
source "$sdkman_switch_jdk_state_helper"

sdkman_switch_jdk_root="${SDKMAN_DIR:-${HOME:?HOME is not set}/.sdkman}"
sdkman_switch_jdk_init="$sdkman_switch_jdk_root/bin/sdkman-init.sh"
if [[ ! -r "$sdkman_switch_jdk_init" ]]; then
  printf 'SDKMAN init script is not readable: %s\n' "$sdkman_switch_jdk_init" >&2
  exit 1
fi

# SDKMAN is a shell function and must be loaded into this process.
# Prevent sdkman_auto_env from applying a project file while SDKMAN initializes.
unset SDKMAN_ENV
export SDKMAN_OLD_PWD="$PWD"
# shellcheck source=/dev/null
source "$sdkman_switch_jdk_init"

if ! type sdk >/dev/null 2>&1; then
  printf 'SDKMAN did not define the sdk command.\n' >&2
  exit 1
fi

sdkman_switch_jdk_java_dir="${SDKMAN_CANDIDATES_DIR:?SDKMAN_CANDIDATES_DIR is not set}/java"
sdkman_switch_jdk_current="$sdkman_switch_jdk_java_dir/current"
sdkman_switch_jdk_target="$sdkman_switch_jdk_java_dir/$sdkman_switch_jdk_identifier"

if ! sdkman_switch_jdk_acquire_lock install-java; then
  exit 1
fi
sdkman_switch_jdk_install_cleanup_traps

sdkman_switch_jdk_default_before="$(sdkman_switch_jdk_default_state "$sdkman_switch_jdk_current")"
if [[ "$sdkman_switch_jdk_default_before" == "unsupported" ]]; then
  printf 'Refusing to continue: SDKMAN Java current is not a symlink: %s\n' \
    "$sdkman_switch_jdk_current" >&2
  exit 1
fi

sdkman_switch_jdk_owned_state=''
if [[ -e "$sdkman_switch_jdk_target" || -L "$sdkman_switch_jdk_target" ]]; then
  if [[ ! -x "$sdkman_switch_jdk_target/bin/java" ]]; then
    printf 'Refusing to use an incomplete SDKMAN Java candidate: %s\n' \
      "$sdkman_switch_jdk_target" >&2
    exit 1
  fi
  sdkman_switch_jdk_install_status=0
else
  sdkman_switch_jdk_owned_state="$(sdkman_switch_jdk_target_state "$sdkman_switch_jdk_identifier")"
  # Pre-seeding USE covers both SDKMAN auto-answer modes and the no-default case.
  # The here-string supplies the same explicit answer when SDKMAN prompts.
  set +e
  USE=n sdk install java "$sdkman_switch_jdk_identifier" <<< 'n'
  sdkman_switch_jdk_install_status=$?
  set -e
fi

sdkman_switch_jdk_default_after="$(sdkman_switch_jdk_default_state "$sdkman_switch_jdk_current")"
sdkman_switch_jdk_default_changed=0

if [[ "$sdkman_switch_jdk_default_after" != "$sdkman_switch_jdk_default_before" ]]; then
  sdkman_switch_jdk_default_changed=1
  if ! sdkman_switch_jdk_restore_default \
      "$sdkman_switch_jdk_current" \
      "$sdkman_switch_jdk_default_before" \
      "$sdkman_switch_jdk_owned_state"; then
    printf 'SDKMAN changed the Java default unexpectedly and automatic restoration failed.\n' >&2
    exit 1
  fi
fi

if (( sdkman_switch_jdk_install_status != 0 )); then
  if ! sdkman_switch_jdk_release_lock; then
    exit 1
  fi
  printf 'SDKMAN failed to install Java %s (status %d); the default is unchanged.\n' \
    "$sdkman_switch_jdk_identifier" "$sdkman_switch_jdk_install_status" >&2
  exit "$sdkman_switch_jdk_install_status"
fi

if (( sdkman_switch_jdk_default_changed != 0 )); then
  if ! sdkman_switch_jdk_release_lock; then
    exit 1
  fi
  printf 'SDKMAN changed the Java default unexpectedly; the previous state was restored.\n' >&2
  exit 1
fi

if [[ ! -x "$sdkman_switch_jdk_target/bin/java" ]]; then
  printf 'SDKMAN reported success but Java is incomplete or not executable at: %s\n' \
    "$sdkman_switch_jdk_target" >&2
  exit 1
fi

if ! sdkman_switch_jdk_release_lock; then
  exit 1
fi

printf 'Java %s is installed; SDKMAN default is unchanged.\n' \
  "$sdkman_switch_jdk_identifier"
