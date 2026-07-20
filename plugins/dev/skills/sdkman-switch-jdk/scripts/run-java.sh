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

sdkman_switch_jdk_run_default_state() {
  if [[ -L "$sdkman_switch_jdk_run_current" ]]; then
    printf 'link:%s\n' "$(readlink "$sdkman_switch_jdk_run_current")"
  elif [[ -e "$sdkman_switch_jdk_run_current" ]]; then
    printf 'unsupported\n'
  else
    printf 'absent\n'
  fi
}

sdkman_switch_jdk_run_replace_default_link() {
  local target="$1"
  local cleanup_status=0
  local move_status
  local temp_dir
  local temp_link

  temp_dir="$(mktemp -d "$sdkman_switch_jdk_run_java_dir/.sdkman-switch-jdk-restore.XXXXXX")" || return 1
  temp_link="$temp_dir/current"

  if ! ln -s "$target" "$temp_link"; then
    rmdir "$temp_dir" 2>/dev/null || true
    return 1
  fi
  if [[ ! -L "$temp_link" || "$(readlink "$temp_link")" != "$target" ]]; then
    unlink "$temp_link" 2>/dev/null || true
    rmdir "$temp_dir" 2>/dev/null || true
    return 1
  fi

  # BSD mv uses -h and GNU mv uses -T to replace a symlink itself rather than
  # following a symlink to a directory. Both paths use rename on this filesystem.
  mv -fh "$temp_link" "$sdkman_switch_jdk_run_current" 2>/dev/null
  move_status=$?
  if (( move_status != 0 )) && [[ -L "$temp_link" ]]; then
    mv -Tf "$temp_link" "$sdkman_switch_jdk_run_current" 2>/dev/null
    move_status=$?
  fi

  if [[ -L "$temp_link" ]]; then
    unlink "$temp_link" || cleanup_status=$?
  fi
  rmdir "$temp_dir" || cleanup_status=$?

  if (( move_status != 0 )); then
    return "$move_status"
  fi
  return "$cleanup_status"
}

sdkman_switch_jdk_run_restore_default() {
  local expected="$1"
  local previous_target
  local restore_status
  local restored

  restored="$(sdkman_switch_jdk_run_default_state)"
  if [[ "$restored" == "$expected" ]]; then
    return 0
  fi

  if [[ "$restored" == "unsupported" ]]; then
    return 1
  fi

  if [[ "$expected" == link:* ]]; then
    previous_target="${expected#link:}"
    set +e
    sdkman_switch_jdk_run_replace_default_link "$previous_target"
    restore_status=$?
    set -e
  elif [[ "$expected" == "absent" && -L "$sdkman_switch_jdk_run_current" ]]; then
    set +e
    unlink "$sdkman_switch_jdk_run_current"
    restore_status=$?
    set -e
  else
    restore_status=1
  fi

  restored="$(sdkman_switch_jdk_run_default_state)"
  if (( restore_status != 0 )) || [[ "$restored" != "$expected" ]]; then
    printf 'Default restoration command exited with status %d.\n' \
      "$restore_status" >&2
    return 1
  fi
}

if [[ ! -x "$sdkman_switch_jdk_run_target/bin/java" ]]; then
  printf 'Java is not installed or is incomplete: %s\n' \
    "$sdkman_switch_jdk_run_identifier" >&2
  exit 1
fi

sdkman_switch_jdk_run_default_before="$(sdkman_switch_jdk_run_default_state)"
if [[ "$sdkman_switch_jdk_run_default_before" == "unsupported" ]]; then
  printf 'Refusing to continue: SDKMAN Java current is not a symlink: %s\n' \
    "$sdkman_switch_jdk_run_current" >&2
  exit 1
fi

sdkman_switch_jdk_run_use_status=0
if [[ "$sdkman_switch_jdk_run_default_before" == link:* ]]; then
  set +e
  sdk use java "$sdkman_switch_jdk_run_identifier"
  sdkman_switch_jdk_run_use_status=$?
  set -e
else
  :
fi

sdkman_switch_jdk_run_default_after="$(sdkman_switch_jdk_run_default_state)"
sdkman_switch_jdk_run_default_changed=0
if [[ "$sdkman_switch_jdk_run_default_after" != "$sdkman_switch_jdk_run_default_before" ]]; then
  sdkman_switch_jdk_run_default_changed=1
  if ! sdkman_switch_jdk_run_restore_default "$sdkman_switch_jdk_run_default_before"; then
    printf 'SDKMAN changed the Java default unexpectedly and automatic restoration failed.\n' >&2
    exit 1
  fi
fi

if (( sdkman_switch_jdk_run_use_status != 0 )); then
  printf 'SDKMAN failed to activate Java %s (status %d); the command was not run.\n' \
    "$sdkman_switch_jdk_run_identifier" "$sdkman_switch_jdk_run_use_status" >&2
  exit "$sdkman_switch_jdk_run_use_status"
fi

if (( sdkman_switch_jdk_run_default_changed != 0 )); then
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
exec "$@"
