#!/usr/bin/env bash

# Shared SDKMAN default-state coordination for the sdkman-switch-jdk runners.
# This file is sourced by the executable scripts and must remain Bash 3.2
# compatible.

# Capture every external cleanup primitive before SDKMAN can prepend an
# activated candidate to PATH.  The runners deliberately invoke SDKMAN after
# sourcing this helper, so later reconciliation does not accidentally execute
# a similarly named program supplied by a candidate.
sdkman_switch_jdk_capture_tool() {
  local variable_name="$1"
  local tool_name="$2"
  local tool_path=''

  tool_path="$(command -v "$tool_name" 2>/dev/null)" || return 1
  if [[ "$tool_path" != /* || ! -f "$tool_path" || ! -x "$tool_path" ]]; then
    return 1
  fi
  printf -v "$variable_name" '%s' "$tool_path"
}

sdkman_switch_jdk_capture_tool_paths() {
  sdkman_switch_jdk_capture_tool sdkman_switch_jdk_cmd_readlink readlink && \
    sdkman_switch_jdk_capture_tool sdkman_switch_jdk_cmd_od od && \
    sdkman_switch_jdk_capture_tool sdkman_switch_jdk_cmd_tr tr && \
    sdkman_switch_jdk_capture_tool sdkman_switch_jdk_cmd_mkdir mkdir && \
    sdkman_switch_jdk_capture_tool sdkman_switch_jdk_cmd_rmdir rmdir && \
    sdkman_switch_jdk_capture_tool sdkman_switch_jdk_cmd_unlink unlink && \
    sdkman_switch_jdk_capture_tool sdkman_switch_jdk_cmd_mktemp mktemp && \
    sdkman_switch_jdk_capture_tool sdkman_switch_jdk_cmd_ln ln && \
    sdkman_switch_jdk_capture_tool sdkman_switch_jdk_cmd_mv mv && \
    sdkman_switch_jdk_capture_tool sdkman_switch_jdk_cmd_cksum cksum
}

if ! sdkman_switch_jdk_capture_tool_paths; then
  printf 'Could not resolve a required SDKMAN state-management tool.\n' >&2
  return 1 2>/dev/null || exit 1
fi

sdkman_switch_jdk_link_state() {
  local link="$1"

  printf 'link-hex:'
  LC_ALL=C "$sdkman_switch_jdk_cmd_readlink" -n "$link" | \
    LC_ALL=C "$sdkman_switch_jdk_cmd_od" -An -v -tx1 | \
    LC_ALL=C "$sdkman_switch_jdk_cmd_tr" -d '[:space:]' || return 1
  printf '\n'
}

sdkman_switch_jdk_default_state() {
  local current="$1"

  if [[ -L "$current" ]]; then
    sdkman_switch_jdk_link_state "$current"
  elif [[ -e "$current" ]]; then
    printf 'unsupported\n'
  else
    printf 'absent\n'
  fi
}

sdkman_switch_jdk_file_fingerprint() {
  local file="$1"

  [[ -f "$file" && ! -L "$file" && -O "$file" && -r "$file" ]] || return 1
  "$sdkman_switch_jdk_cmd_cksum" < "$file"
}

sdkman_switch_jdk_target_state() {
  local target="$1"

  printf 'link-hex:'
  printf '%s' "$target" | LC_ALL=C "$sdkman_switch_jdk_cmd_od" -An -v -tx1 | \
    LC_ALL=C "$sdkman_switch_jdk_cmd_tr" -d '[:space:]' || return 1
  printf '\n'
}

sdkman_switch_jdk_decode_link_state() {
  local encoded="${1#link-hex:}"
  local escaped=''

  if [[ "$1" != link-hex:* || -z "$encoded" || \
        $(( ${#encoded} % 2 )) -ne 0 || \
        ! "$encoded" =~ ^[0-9A-Fa-f]+$ ]]; then
    return 1
  fi
  while [[ -n "$encoded" ]]; do
    escaped="${escaped}\\x${encoded:0:2}"
    encoded="${encoded:2}"
  done
  printf -v sdkman_switch_jdk_decoded_target '%b' "$escaped"
}

sdkman_switch_jdk_lock_dir=''
sdkman_switch_jdk_lock_owned=0
sdkman_switch_jdk_lock_token=''
sdkman_switch_jdk_lock_label=''
sdkman_switch_jdk_lock_acquire_in_progress=0
sdkman_switch_jdk_lock_initializing=0
sdkman_switch_jdk_restore_temp_dir=''
sdkman_switch_jdk_restore_temp_link=''
sdkman_switch_jdk_reconcile_callback=''
sdkman_switch_jdk_cleanup_running=0
sdkman_switch_jdk_deferred_signal_status=0
sdkman_switch_jdk_default_reconcile_current=''
sdkman_switch_jdk_default_reconcile_before=''
sdkman_switch_jdk_default_reconcile_owned=''
sdkman_switch_jdk_default_reconcile_changed=0
sdkman_switch_jdk_default_reconcile_failed=0

sdkman_switch_jdk_read_lock_field() {
  local file="$1"
  local value=''
  local extra=''

  [[ -f "$file" && ! -L "$file" && -O "$file" ]] || return 1
  exec 9< "$file" || return 1
  if ! IFS= read -r value <&9; then
    exec 9<&-
    return 1
  fi
  if IFS= read -r extra <&9 || [[ -n "$extra" ]]; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  sdkman_switch_jdk_lock_field_value="$value"
}

sdkman_switch_jdk_snapshot_lock() {
  local lock_dir="$1"

  [[ -d "$lock_dir" && ! -L "$lock_dir" && -O "$lock_dir" ]] || return 1
  sdkman_switch_jdk_read_lock_field "$lock_dir/pid" || return 1
  sdkman_switch_jdk_snapshot_pid="$sdkman_switch_jdk_lock_field_value"
  sdkman_switch_jdk_read_lock_field "$lock_dir/euid" || return 1
  sdkman_switch_jdk_snapshot_euid="$sdkman_switch_jdk_lock_field_value"
  sdkman_switch_jdk_read_lock_field "$lock_dir/token" || return 1
  sdkman_switch_jdk_snapshot_token="$sdkman_switch_jdk_lock_field_value"
  sdkman_switch_jdk_read_lock_field "$lock_dir/label" || return 1
  sdkman_switch_jdk_snapshot_label="$sdkman_switch_jdk_lock_field_value"

  [[ "$sdkman_switch_jdk_snapshot_pid" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$sdkman_switch_jdk_snapshot_euid" =~ ^[0-9]+$ ]] || return 1
  [[ "$sdkman_switch_jdk_snapshot_token" =~ ^${sdkman_switch_jdk_snapshot_pid}:${sdkman_switch_jdk_snapshot_euid}:[A-Za-z0-9._-]+:[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$sdkman_switch_jdk_snapshot_label" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
}

sdkman_switch_jdk_remove_owned_lock_files() {
  local cleanup_status=0

  if [[ -f "$sdkman_switch_jdk_lock_dir/pid" && ! -L "$sdkman_switch_jdk_lock_dir/pid" ]]; then
    "$sdkman_switch_jdk_cmd_unlink" "$sdkman_switch_jdk_lock_dir/pid" || cleanup_status=1
  else
    cleanup_status=1
  fi
  if [[ -f "$sdkman_switch_jdk_lock_dir/euid" && ! -L "$sdkman_switch_jdk_lock_dir/euid" ]]; then
    "$sdkman_switch_jdk_cmd_unlink" "$sdkman_switch_jdk_lock_dir/euid" || cleanup_status=1
  else
    cleanup_status=1
  fi
  if [[ -f "$sdkman_switch_jdk_lock_dir/token" && ! -L "$sdkman_switch_jdk_lock_dir/token" ]]; then
    "$sdkman_switch_jdk_cmd_unlink" "$sdkman_switch_jdk_lock_dir/token" || cleanup_status=1
  else
    cleanup_status=1
  fi
  if [[ -f "$sdkman_switch_jdk_lock_dir/label" && ! -L "$sdkman_switch_jdk_lock_dir/label" ]]; then
    "$sdkman_switch_jdk_cmd_unlink" "$sdkman_switch_jdk_lock_dir/label" || cleanup_status=1
  else
    cleanup_status=1
  fi
  return "$cleanup_status"
}

sdkman_switch_jdk_cleanup_initializing_lock() {
  local cleanup_status=0
  local field
  local expected_value

  if (( sdkman_switch_jdk_lock_initializing == 0 )); then
    return 0
  fi
  if [[ ! -d "$sdkman_switch_jdk_lock_dir" || \
        -L "$sdkman_switch_jdk_lock_dir" || \
        ! -O "$sdkman_switch_jdk_lock_dir" ]]; then
    return 1
  fi

  for field in pid euid token label; do
    case "$field" in
      pid) expected_value="$$" ;;
      euid) expected_value="$EUID" ;;
      token) expected_value="$sdkman_switch_jdk_lock_token" ;;
      label) expected_value="$sdkman_switch_jdk_lock_label" ;;
    esac
    if [[ ! -e "$sdkman_switch_jdk_lock_dir/$field" && \
          ! -L "$sdkman_switch_jdk_lock_dir/$field" ]]; then
      continue
    fi
    if [[ -z "$expected_value" ]] || \
       ! sdkman_switch_jdk_read_lock_field "$sdkman_switch_jdk_lock_dir/$field" || \
       [[ "$sdkman_switch_jdk_lock_field_value" != "$expected_value" ]] || \
       ! "$sdkman_switch_jdk_cmd_unlink" "$sdkman_switch_jdk_lock_dir/$field"; then
      cleanup_status=1
    fi
  done
  if ! "$sdkman_switch_jdk_cmd_rmdir" "$sdkman_switch_jdk_lock_dir"; then
    cleanup_status=1
  fi
  if (( cleanup_status != 0 )); then
    printf 'Failed to clean up an initializing SDKMAN default-state lock.\n' >&2
    return 1
  fi
  sdkman_switch_jdk_lock_initializing=0
  sdkman_switch_jdk_lock_token=''
  sdkman_switch_jdk_lock_label=''
}

sdkman_switch_jdk_reap_stale_lock() {
  local expected_pid="$sdkman_switch_jdk_snapshot_pid"
  local expected_euid="$sdkman_switch_jdk_snapshot_euid"
  local expected_token="$sdkman_switch_jdk_snapshot_token"
  local expected_label="$sdkman_switch_jdk_snapshot_label"
  local reaper_dir="$sdkman_switch_jdk_lock_dir/reap"
  local cleanup_status=0
  local old_umask

  if [[ "$expected_euid" != "$EUID" ]]; then
    printf 'Refusing to recover an SDKMAN lock owned by another user.\n' >&2
    return 1
  fi
  if kill -0 "$expected_pid" 2>/dev/null; then
    printf 'SDKMAN default-state lock is held by live process %s (%s).\n' \
      "$expected_pid" "$expected_label" >&2
    return 1
  fi
  old_umask="$(umask)"
  umask 077
  if ! "$sdkman_switch_jdk_cmd_mkdir" "$reaper_dir" 2>/dev/null; then
    umask "$old_umask"
    printf 'SDKMAN default-state lock is being recovered by another process.\n' >&2
    return 1
  fi
  umask "$old_umask"

  if ! sdkman_switch_jdk_snapshot_lock "$sdkman_switch_jdk_lock_dir" || \
     [[ "$sdkman_switch_jdk_snapshot_pid" != "$expected_pid" ]] || \
     [[ "$sdkman_switch_jdk_snapshot_euid" != "$expected_euid" ]] || \
     [[ "$sdkman_switch_jdk_snapshot_token" != "$expected_token" ]] || \
     [[ "$sdkman_switch_jdk_snapshot_label" != "$expected_label" ]] || \
     kill -0 "$expected_pid" 2>/dev/null; then
    "$sdkman_switch_jdk_cmd_rmdir" "$reaper_dir" 2>/dev/null || true
    printf 'SDKMAN default-state lock changed during stale-lock recovery.\n' >&2
    return 1
  fi

  sdkman_switch_jdk_remove_owned_lock_files || cleanup_status=1
  "$sdkman_switch_jdk_cmd_rmdir" "$reaper_dir" || cleanup_status=1
  "$sdkman_switch_jdk_cmd_rmdir" "$sdkman_switch_jdk_lock_dir" || cleanup_status=1
  if (( cleanup_status != 0 )); then
    printf 'Failed to clean up a stale SDKMAN default-state lock.\n' >&2
    return 1
  fi
}

sdkman_switch_jdk_create_lock() {
  local nonce
  local old_umask

  sdkman_switch_jdk_lock_initializing=1
  old_umask="$(umask)"
  umask 077
  nonce="$(
    LC_ALL=C "$sdkman_switch_jdk_cmd_od" -An -N 16 -tx1 /dev/urandom | \
      LC_ALL=C "$sdkman_switch_jdk_cmd_tr" -d '[:space:]'
  )" || nonce=''
  if [[ ! "$nonce" =~ ^[0-9a-f]{32}$ ]]; then
    umask "$old_umask"
    sdkman_switch_jdk_cleanup_initializing_lock || true
    printf 'Failed to create an SDKMAN default-state lock token.\n' >&2
    return 1
  fi
  sdkman_switch_jdk_lock_token="$$:${EUID}:${nonce:0:16}:${nonce:16:16}"
  if ! printf '%s\n' "$$" > "$sdkman_switch_jdk_lock_dir/pid" || \
     ! printf '%s\n' "$EUID" > "$sdkman_switch_jdk_lock_dir/euid" || \
     ! printf '%s\n' "$sdkman_switch_jdk_lock_token" > "$sdkman_switch_jdk_lock_dir/token" || \
     ! printf '%s\n' "$sdkman_switch_jdk_lock_label" > "$sdkman_switch_jdk_lock_dir/label"; then
    umask "$old_umask"
    sdkman_switch_jdk_cleanup_initializing_lock || true
    printf 'Failed to initialize the SDKMAN default-state lock.\n' >&2
    return 1
  fi
  umask "$old_umask"
  sdkman_switch_jdk_lock_owned=1
  sdkman_switch_jdk_lock_initializing=0
}

sdkman_switch_jdk_acquire_lock() {
  local label="$1"
  local attempt=0
  local old_umask
  local create_status=0

  if [[ ! "$label" =~ ^[A-Za-z0-9._-]+$ ]]; then
    printf 'Invalid SDKMAN default-state lock label.\n' >&2
    return 1
  fi
  sdkman_switch_jdk_lock_dir="${SDKMAN_CANDIDATES_DIR:?SDKMAN_CANDIDATES_DIR is not set}/.sdkman-switch-jdk.lock"
  sdkman_switch_jdk_lock_label="$label"

  while (( attempt < 2 )); do
    old_umask="$(umask)"
    umask 077
    sdkman_switch_jdk_lock_acquire_in_progress=1
    if "$sdkman_switch_jdk_cmd_mkdir" "$sdkman_switch_jdk_lock_dir" 2>/dev/null; then
      umask "$old_umask"
      sdkman_switch_jdk_create_lock
      create_status=$?
      sdkman_switch_jdk_lock_acquire_in_progress=0
      if (( create_status != 0 )); then
        if (( sdkman_switch_jdk_deferred_signal_status != 0 )); then
          sdkman_switch_jdk_exit_with_cleanup \
            "$sdkman_switch_jdk_deferred_signal_status"
        fi
        return 1
      fi
      if (( sdkman_switch_jdk_deferred_signal_status != 0 )); then
        sdkman_switch_jdk_exit_with_cleanup \
          "$sdkman_switch_jdk_deferred_signal_status"
      fi
      return 0
    fi
    umask "$old_umask"
    sdkman_switch_jdk_lock_acquire_in_progress=0
    if (( sdkman_switch_jdk_deferred_signal_status != 0 )); then
      sdkman_switch_jdk_exit_with_cleanup \
        "$sdkman_switch_jdk_deferred_signal_status"
    fi
    if [[ -L "$sdkman_switch_jdk_lock_dir" || \
          ( -e "$sdkman_switch_jdk_lock_dir" && \
            ! -d "$sdkman_switch_jdk_lock_dir" ) ]]; then
      printf 'SDKMAN default-state lock path is unsafe: %s\n' \
        "$sdkman_switch_jdk_lock_dir" >&2
      return 1
    fi
    if [[ ! -d "$sdkman_switch_jdk_lock_dir" ]]; then
      printf 'Could not create the SDKMAN default-state lock: %s\n' \
        "$sdkman_switch_jdk_lock_dir" >&2
      printf 'The path was absent when checked; verify that its parent exists and is writable.\n' >&2
      return 1
    fi
    if ! sdkman_switch_jdk_snapshot_lock "$sdkman_switch_jdk_lock_dir"; then
      printf 'SDKMAN default-state lock metadata is incomplete or unsafe.\n' >&2
      return 1
    fi
    if ! sdkman_switch_jdk_reap_stale_lock; then
      return 1
    fi
    attempt=$((attempt + 1))
  done

  printf 'Could not acquire the SDKMAN default-state lock.\n' >&2
  return 1
}

sdkman_switch_jdk_release_lock() {
  local cleanup_status=0

  if (( sdkman_switch_jdk_lock_owned == 0 )); then
    return 0
  fi
  if ! sdkman_switch_jdk_snapshot_lock "$sdkman_switch_jdk_lock_dir" || \
     [[ "$sdkman_switch_jdk_snapshot_pid" != "$$" ]] || \
     [[ "$sdkman_switch_jdk_snapshot_euid" != "$EUID" ]] || \
     [[ "$sdkman_switch_jdk_snapshot_token" != "$sdkman_switch_jdk_lock_token" ]] || \
     [[ "$sdkman_switch_jdk_snapshot_label" != "$sdkman_switch_jdk_lock_label" ]]; then
    printf 'Refusing to release an SDKMAN lock whose ownership changed.\n' >&2
    return 1
  fi

  sdkman_switch_jdk_remove_owned_lock_files || cleanup_status=1
  "$sdkman_switch_jdk_cmd_rmdir" "$sdkman_switch_jdk_lock_dir" || cleanup_status=1
  if (( cleanup_status != 0 )); then
    printf 'Failed to release the SDKMAN default-state lock.\n' >&2
    return 1
  fi
  sdkman_switch_jdk_lock_owned=0
  sdkman_switch_jdk_lock_token=''
  sdkman_switch_jdk_lock_label=''
}

sdkman_switch_jdk_cleanup_restore_temp() {
  local cleanup_status=0

  if [[ -n "$sdkman_switch_jdk_restore_temp_link" && \
        -L "$sdkman_switch_jdk_restore_temp_link" ]]; then
    "$sdkman_switch_jdk_cmd_unlink" "$sdkman_switch_jdk_restore_temp_link" || cleanup_status=1
  fi
  if [[ -n "$sdkman_switch_jdk_restore_temp_dir" && \
        -d "$sdkman_switch_jdk_restore_temp_dir" ]]; then
    "$sdkman_switch_jdk_cmd_rmdir" "$sdkman_switch_jdk_restore_temp_dir" || cleanup_status=1
  fi
  sdkman_switch_jdk_restore_temp_link=''
  sdkman_switch_jdk_restore_temp_dir=''
  return "$cleanup_status"
}

sdkman_switch_jdk_register_reconcile_callback() {
  local callback="$1"

  if [[ ! "$callback" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || \
     ! type "$callback" >/dev/null 2>&1 || \
     [[ -n "$sdkman_switch_jdk_reconcile_callback" ]]; then
    printf 'Could not register the SDKMAN reconciliation callback.\n' >&2
    return 1
  fi
  sdkman_switch_jdk_reconcile_callback="$callback"
}

sdkman_switch_jdk_reconcile_registered_default() {
  local default_after

  default_after="$(
    sdkman_switch_jdk_default_state "$sdkman_switch_jdk_default_reconcile_current"
  )" || {
    sdkman_switch_jdk_default_reconcile_failed=1
    return 1
  }
  if [[ "$default_after" == "$sdkman_switch_jdk_default_reconcile_before" ]]; then
    return 0
  fi

  sdkman_switch_jdk_default_reconcile_changed=1
  if ! sdkman_switch_jdk_restore_default \
      "$sdkman_switch_jdk_default_reconcile_current" \
      "$sdkman_switch_jdk_default_reconcile_before" \
      "$sdkman_switch_jdk_default_reconcile_owned"; then
    sdkman_switch_jdk_default_reconcile_failed=1
    printf 'SDKMAN changed the Java default unexpectedly and automatic restoration failed.\n' >&2
    return 1
  fi
}

sdkman_switch_jdk_register_default_reconciliation() {
  sdkman_switch_jdk_default_reconcile_current="$1"
  sdkman_switch_jdk_default_reconcile_before="$2"
  sdkman_switch_jdk_default_reconcile_owned="$3"
  sdkman_switch_jdk_default_reconcile_changed=0
  sdkman_switch_jdk_default_reconcile_failed=0
  sdkman_switch_jdk_register_reconcile_callback \
    sdkman_switch_jdk_reconcile_registered_default
}

sdkman_switch_jdk_run_reconcile_callback() {
  local callback="$sdkman_switch_jdk_reconcile_callback"

  sdkman_switch_jdk_reconcile_callback=''
  if [[ -z "$callback" ]]; then
    return 0
  fi
  "$callback"
}

sdkman_switch_jdk_finish_operation() {
  local requested_status="$1"
  local cleanup_status=0

  if [[ ! "$requested_status" =~ ^[0-9]+$ ]] || \
     (( requested_status > 255 || sdkman_switch_jdk_cleanup_running != 0 )); then
    return 1
  fi

  sdkman_switch_jdk_cleanup_running=1
  if ! sdkman_switch_jdk_run_reconcile_callback; then
    cleanup_status=1
  fi
  if ! sdkman_switch_jdk_cleanup_restore_temp; then
    cleanup_status=1
  fi
  if ! sdkman_switch_jdk_cleanup_initializing_lock; then
    cleanup_status=1
  fi
  if ! sdkman_switch_jdk_release_lock; then
    cleanup_status=1
  fi
  sdkman_switch_jdk_cleanup_running=0

  if (( cleanup_status != 0 )); then
    return 1
  fi
  if (( sdkman_switch_jdk_deferred_signal_status != 0 )); then
    return "$sdkman_switch_jdk_deferred_signal_status"
  fi
  return "$requested_status"
}

sdkman_switch_jdk_exit_with_cleanup() {
  local exit_status="$1"

  trap - EXIT
  set +e
  sdkman_switch_jdk_finish_operation "$exit_status"
  exit_status=$?
  trap - HUP INT TERM
  exit "$exit_status"
}

sdkman_switch_jdk_handle_signal() {
  local signal_status="$1"

  if (( sdkman_switch_jdk_cleanup_running != 0 || \
        sdkman_switch_jdk_lock_acquire_in_progress != 0 || \
        sdkman_switch_jdk_lock_initializing != 0 )); then
    if (( sdkman_switch_jdk_deferred_signal_status == 0 )); then
      sdkman_switch_jdk_deferred_signal_status="$signal_status"
    fi
    return 0
  fi
  exit "$signal_status"
}

sdkman_switch_jdk_install_cleanup_traps() {
  sdkman_switch_jdk_deferred_signal_status=0
  trap 'sdkman_switch_jdk_exit_with_cleanup "$?"' EXIT
  trap 'sdkman_switch_jdk_handle_signal 129' HUP
  trap 'sdkman_switch_jdk_handle_signal 130' INT
  trap 'sdkman_switch_jdk_handle_signal 143' TERM
}

sdkman_switch_jdk_clear_cleanup_traps() {
  trap - EXIT HUP INT TERM
}

sdkman_switch_jdk_restore_default() {
  local current="$1"
  local previous_state="$2"
  local owned_state="$3"
  local actual_state
  local restore_status=0
  local move_status=0
  local cleanup_status=0
  local current_dir="${current%/*}"

  actual_state="$(sdkman_switch_jdk_default_state "$current")" || return 1
  if [[ "$actual_state" == "$previous_state" ]]; then
    return 0
  fi
  if [[ -z "$owned_state" || "$actual_state" != "$owned_state" ]]; then
    printf 'Default drifted after the SDKMAN operation; refusing to restore.\n' >&2
    return 1
  fi

  if [[ "$previous_state" == link-hex:* ]] && \
     sdkman_switch_jdk_decode_link_state "$previous_state"; then
    sdkman_switch_jdk_restore_temp_dir="$("$sdkman_switch_jdk_cmd_mktemp" -d "$current_dir/.sdkman-switch-jdk-restore.XXXXXX")" || return 1
    sdkman_switch_jdk_restore_temp_link="$sdkman_switch_jdk_restore_temp_dir/current"
    if ! "$sdkman_switch_jdk_cmd_ln" -s -- "$sdkman_switch_jdk_decoded_target" "$sdkman_switch_jdk_restore_temp_link" || \
       [[ ! -L "$sdkman_switch_jdk_restore_temp_link" ]] || \
       [[ "$(sdkman_switch_jdk_link_state "$sdkman_switch_jdk_restore_temp_link")" != "$previous_state" ]]; then
      sdkman_switch_jdk_cleanup_restore_temp || true
      return 1
    fi

    actual_state="$(sdkman_switch_jdk_default_state "$current")" || restore_status=1
    if (( restore_status != 0 )) || [[ "$actual_state" != "$owned_state" ]]; then
      printf 'Default rollback drift detected; refusing to overwrite a concurrent change.\n' >&2
      sdkman_switch_jdk_cleanup_restore_temp || true
      return 1
    fi

    if "$sdkman_switch_jdk_cmd_mv" -fh "$sdkman_switch_jdk_restore_temp_link" "$current" 2>/dev/null; then
      move_status=0
    else
      move_status=$?
    fi
    if (( move_status != 0 )) && [[ -L "$sdkman_switch_jdk_restore_temp_link" ]]; then
      actual_state="$(sdkman_switch_jdk_default_state "$current")" || restore_status=1
      if (( restore_status != 0 )) || [[ "$actual_state" != "$owned_state" ]]; then
        printf 'Default rollback drift detected before the GNU fallback; refusing to overwrite a concurrent change.\n' >&2
        sdkman_switch_jdk_cleanup_restore_temp || true
        return 1
      fi
      if "$sdkman_switch_jdk_cmd_mv" -Tf "$sdkman_switch_jdk_restore_temp_link" "$current" 2>/dev/null; then
        move_status=0
      else
        move_status=$?
      fi
    fi
    sdkman_switch_jdk_cleanup_restore_temp || cleanup_status=1
    if (( move_status != 0 || cleanup_status != 0 )); then
      restore_status=1
    fi
  elif [[ "$previous_state" == "absent" && -L "$current" ]]; then
    actual_state="$(sdkman_switch_jdk_default_state "$current")" || restore_status=1
    if (( restore_status != 0 )) || [[ "$actual_state" != "$owned_state" ]]; then
      printf 'Default rollback drift detected; refusing to remove a concurrent change.\n' >&2
      return 1
    fi
    "$sdkman_switch_jdk_cmd_unlink" "$current" || restore_status=1
  else
    restore_status=1
  fi

  actual_state="$(sdkman_switch_jdk_default_state "$current")" || restore_status=1
  if (( restore_status != 0 )) || [[ "$actual_state" != "$previous_state" ]]; then
    printf 'Default restoration command did not restore the exact previous state.\n' >&2
    return 1
  fi
}
