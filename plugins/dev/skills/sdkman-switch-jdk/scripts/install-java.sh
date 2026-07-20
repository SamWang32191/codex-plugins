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

sdkman_switch_jdk_link_state() {
  local link="$1"

  printf 'link-hex:'
  LC_ALL=C readlink -n "$link" | LC_ALL=C od -An -v -tx1 | \
    LC_ALL=C tr -d '[:space:]' || return 1
  printf '\n'
}

sdkman_switch_jdk_default_state() {
  if [[ -L "$sdkman_switch_jdk_current" ]]; then
    sdkman_switch_jdk_link_state "$sdkman_switch_jdk_current"
  elif [[ -e "$sdkman_switch_jdk_current" ]]; then
    printf 'unsupported\n'
  else
    printf 'absent\n'
  fi
}

sdkman_switch_jdk_decode_link_state() {
  local encoded="${1#link-hex:}"
  local escaped=''

  if [[ "$1" != link-hex:* || -z "$encoded" || \
        $(( ${#encoded} % 2 )) -ne 0 || \
        ! "$encoded" =~ ^[[:xdigit:]]+$ ]]; then
    return 1
  fi
  while [[ -n "$encoded" ]]; do
    escaped="${escaped}\\x${encoded:0:2}"
    encoded="${encoded:2}"
  done
  printf -v sdkman_switch_jdk_decoded_target '%b' "$escaped"
}

sdkman_switch_jdk_replace_default_link() {
  local target="$1"
  local expected_state="$2"
  local cleanup_status=0
  local move_status
  local temp_dir
  local temp_link

  temp_dir="$(mktemp -d "$sdkman_switch_jdk_java_dir/.sdkman-switch-jdk-restore.XXXXXX")" || return 1
  temp_link="$temp_dir/current"

  if ! ln -s -- "$target" "$temp_link"; then
    rmdir "$temp_dir" 2>/dev/null || true
    return 1
  fi
  if [[ ! -L "$temp_link" ]] || \
     [[ "$(sdkman_switch_jdk_link_state "$temp_link")" != "$expected_state" ]]; then
    unlink "$temp_link" 2>/dev/null || true
    rmdir "$temp_dir" 2>/dev/null || true
    return 1
  fi

  # BSD mv uses -h and GNU mv uses -T to replace a symlink itself rather than
  # following a symlink to a directory. Both paths use rename on this filesystem.
  mv -fh "$temp_link" "$sdkman_switch_jdk_current" 2>/dev/null
  move_status=$?
  if (( move_status != 0 )) && [[ -L "$temp_link" ]]; then
    mv -Tf "$temp_link" "$sdkman_switch_jdk_current" 2>/dev/null
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

sdkman_switch_jdk_restore_default() {
  local expected="$1"
  local previous_target
  local restore_status
  local restored

  restored="$(sdkman_switch_jdk_default_state)"
  if [[ "$restored" == "$expected" ]]; then
    return 0
  fi

  if [[ "$restored" == "unsupported" ]]; then
    return 1
  fi

  if [[ "$expected" == link-hex:* ]] && \
     sdkman_switch_jdk_decode_link_state "$expected"; then
    previous_target="$sdkman_switch_jdk_decoded_target"
    set +e
    sdkman_switch_jdk_replace_default_link "$previous_target" "$expected"
    restore_status=$?
    set -e
  elif [[ "$expected" == "absent" && -L "$sdkman_switch_jdk_current" ]]; then
    set +e
    unlink "$sdkman_switch_jdk_current"
    restore_status=$?
    set -e
  else
    restore_status=1
  fi

  restored="$(sdkman_switch_jdk_default_state)"
  if (( restore_status != 0 )) || [[ "$restored" != "$expected" ]]; then
    printf 'Default restoration command exited with status %d.\n' \
      "$restore_status" >&2
    return 1
  fi
}

sdkman_switch_jdk_default_before="$(sdkman_switch_jdk_default_state)"
if [[ "$sdkman_switch_jdk_default_before" == "unsupported" ]]; then
  printf 'Refusing to continue: SDKMAN Java current is not a symlink: %s\n' \
    "$sdkman_switch_jdk_current" >&2
  exit 1
fi

if [[ -e "$sdkman_switch_jdk_target" || -L "$sdkman_switch_jdk_target" ]]; then
  if [[ ! -x "$sdkman_switch_jdk_target/bin/java" ]]; then
    printf 'Refusing to use an incomplete SDKMAN Java candidate: %s\n' \
      "$sdkman_switch_jdk_target" >&2
    exit 1
  fi
  sdkman_switch_jdk_install_status=0
else
  # Pre-seeding USE covers both SDKMAN auto-answer modes and the no-default case.
  # The here-string supplies the same explicit answer when SDKMAN prompts.
  set +e
  USE=n sdk install java "$sdkman_switch_jdk_identifier" <<< 'n'
  sdkman_switch_jdk_install_status=$?
  set -e
fi

sdkman_switch_jdk_default_after="$(sdkman_switch_jdk_default_state)"
sdkman_switch_jdk_default_changed=0

if [[ "$sdkman_switch_jdk_default_after" != "$sdkman_switch_jdk_default_before" ]]; then
  sdkman_switch_jdk_default_changed=1
  if ! sdkman_switch_jdk_restore_default "$sdkman_switch_jdk_default_before"; then
    printf 'SDKMAN changed the Java default unexpectedly and automatic restoration failed.\n' >&2
    exit 1
  fi
fi

if (( sdkman_switch_jdk_install_status != 0 )); then
  printf 'SDKMAN failed to install Java %s (status %d); the default is unchanged.\n' \
    "$sdkman_switch_jdk_identifier" "$sdkman_switch_jdk_install_status" >&2
  exit "$sdkman_switch_jdk_install_status"
fi

if (( sdkman_switch_jdk_default_changed != 0 )); then
  printf 'SDKMAN changed the Java default unexpectedly; the previous state was restored.\n' >&2
  exit 1
fi

if [[ ! -x "$sdkman_switch_jdk_target/bin/java" ]]; then
  printf 'SDKMAN reported success but Java is incomplete or not executable at: %s\n' \
    "$sdkman_switch_jdk_target" >&2
  exit 1
fi

printf 'Java %s is installed; SDKMAN default is unchanged.\n' \
  "$sdkman_switch_jdk_identifier"
