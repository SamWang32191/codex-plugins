#!/usr/bin/env bash

set -e -o pipefail

sdkman_switch_jdk_env_usage() {
  printf 'Usage: %s [--allow-default <candidate>]... -- <command> [args...]\n' \
    "${0##*/}" >&2
}

sdkman_switch_jdk_env_allowed_candidates=()
while (( $# > 0 )); do
  case "$1" in
    --allow-default)
      if (( $# < 2 )); then
        sdkman_switch_jdk_env_usage
        exit 2
      fi
      sdkman_switch_jdk_env_allowed_candidates+=("$2")
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      sdkman_switch_jdk_env_usage
      exit 2
      ;;
  esac
done
if (( $# == 0 )); then
  sdkman_switch_jdk_env_usage
  exit 2
fi
sdkman_switch_jdk_env_payload=("$@")

sdkman_switch_jdk_env_index=0
while (( sdkman_switch_jdk_env_index < ${#sdkman_switch_jdk_env_allowed_candidates[@]} )); do
  sdkman_switch_jdk_env_candidate="${sdkman_switch_jdk_env_allowed_candidates[$sdkman_switch_jdk_env_index]}"
  if [[ ! "$sdkman_switch_jdk_env_candidate" =~ ^[a-z][a-z0-9-]*$ ]]; then
    printf 'Invalid SDKMAN default authorization: %s\n' \
      "$sdkman_switch_jdk_env_candidate" >&2
    exit 2
  fi
  sdkman_switch_jdk_env_other=$((sdkman_switch_jdk_env_index + 1))
  while (( sdkman_switch_jdk_env_other < ${#sdkman_switch_jdk_env_allowed_candidates[@]} )); do
    if [[ "${sdkman_switch_jdk_env_allowed_candidates[$sdkman_switch_jdk_env_other]}" == \
          "$sdkman_switch_jdk_env_candidate" ]]; then
      printf 'Duplicate SDKMAN default authorization: %s\n' \
        "$sdkman_switch_jdk_env_candidate" >&2
      exit 2
    fi
    sdkman_switch_jdk_env_other=$((sdkman_switch_jdk_env_other + 1))
  done
  sdkman_switch_jdk_env_index=$((sdkman_switch_jdk_env_index + 1))
done

sdkman_switch_jdk_env_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sdkman_switch_jdk_env_state_helper="$sdkman_switch_jdk_env_script_dir/sdkman-current-state.sh"
if [[ ! -r "$sdkman_switch_jdk_env_state_helper" ]]; then
  printf 'SDKMAN state helper is not readable: %s\n' \
    "$sdkman_switch_jdk_env_state_helper" >&2
  exit 1
fi
# shellcheck source=sdkman-current-state.sh
source "$sdkman_switch_jdk_env_state_helper"

sdkman_switch_jdk_env_project_pwd="$PWD"
sdkman_switch_jdk_env_rc="$sdkman_switch_jdk_env_project_pwd/.sdkmanrc"

if [[ ! -f "$sdkman_switch_jdk_env_rc" || -L "$sdkman_switch_jdk_env_rc" || \
      ! -O "$sdkman_switch_jdk_env_rc" || ! -r "$sdkman_switch_jdk_env_rc" ]]; then
  printf 'SDKMAN environment file must be a readable, owned regular file: %s\n' \
    "$sdkman_switch_jdk_env_rc" >&2
  exit 2
fi

sdkman_switch_jdk_env_rc_fingerprint="$(
  sdkman_switch_jdk_file_fingerprint "$sdkman_switch_jdk_env_rc"
)" || {
  printf 'Could not fingerprint the project .sdkmanrc safely.\n' >&2
  exit 1
}

sdkman_switch_jdk_env_candidates=()
sdkman_switch_jdk_env_versions=()
sdkman_switch_jdk_env_line_number=0
while IFS= read -r sdkman_switch_jdk_env_line || \
      [[ -n "$sdkman_switch_jdk_env_line" ]]; do
  sdkman_switch_jdk_env_line_number=$((sdkman_switch_jdk_env_line_number + 1))
  sdkman_switch_jdk_env_line="${sdkman_switch_jdk_env_line%%#*}"
  sdkman_switch_jdk_env_line="$(
    printf '%s' "$sdkman_switch_jdk_env_line" | \
      LC_ALL=C "$sdkman_switch_jdk_cmd_tr" -d '[:space:]'
  )"
  if [[ -z "$sdkman_switch_jdk_env_line" ]]; then
    continue
  fi
  if [[ "$sdkman_switch_jdk_env_line" != *=* ]]; then
    printf 'Malformed .sdkmanrc entry at line %d.\n' \
      "$sdkman_switch_jdk_env_line_number" >&2
    exit 2
  fi
  sdkman_switch_jdk_env_candidate="${sdkman_switch_jdk_env_line%%=*}"
  sdkman_switch_jdk_env_version="${sdkman_switch_jdk_env_line#*=}"
  if [[ ! "$sdkman_switch_jdk_env_candidate" =~ ^[a-z][a-z0-9-]*$ || \
        ! "$sdkman_switch_jdk_env_version" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ || \
        "$sdkman_switch_jdk_env_version" == "current" ]]; then
    printf 'Malformed .sdkmanrc entry at line %d.\n' \
      "$sdkman_switch_jdk_env_line_number" >&2
    exit 2
  fi
  sdkman_switch_jdk_env_index=0
  while (( sdkman_switch_jdk_env_index < ${#sdkman_switch_jdk_env_candidates[@]} )); do
    if [[ "${sdkman_switch_jdk_env_candidates[$sdkman_switch_jdk_env_index]}" == \
          "$sdkman_switch_jdk_env_candidate" ]]; then
      printf 'Duplicate SDKMAN candidate in .sdkmanrc: %s\n' \
        "$sdkman_switch_jdk_env_candidate" >&2
      exit 2
    fi
    sdkman_switch_jdk_env_index=$((sdkman_switch_jdk_env_index + 1))
  done
  sdkman_switch_jdk_env_candidates+=("$sdkman_switch_jdk_env_candidate")
  sdkman_switch_jdk_env_versions+=("$sdkman_switch_jdk_env_version")
done < "$sdkman_switch_jdk_env_rc"

if (( ${#sdkman_switch_jdk_env_candidates[@]} == 0 )); then
  printf 'No SDKMAN candidates were found in .sdkmanrc.\n' >&2
  exit 2
fi

sdkman_switch_jdk_env_index=0
while (( sdkman_switch_jdk_env_index < ${#sdkman_switch_jdk_env_allowed_candidates[@]} )); do
  sdkman_switch_jdk_env_allowed="${sdkman_switch_jdk_env_allowed_candidates[$sdkman_switch_jdk_env_index]}"
  sdkman_switch_jdk_env_found=0
  sdkman_switch_jdk_env_other=0
  while (( sdkman_switch_jdk_env_other < ${#sdkman_switch_jdk_env_candidates[@]} )); do
    if [[ "${sdkman_switch_jdk_env_candidates[$sdkman_switch_jdk_env_other]}" == \
          "$sdkman_switch_jdk_env_allowed" ]]; then
      sdkman_switch_jdk_env_found=1
      break
    fi
    sdkman_switch_jdk_env_other=$((sdkman_switch_jdk_env_other + 1))
  done
  if (( sdkman_switch_jdk_env_found == 0 )); then
    printf 'Authorized candidate is not present in .sdkmanrc: %s\n' \
      "$sdkman_switch_jdk_env_allowed" >&2
    exit 2
  fi
  sdkman_switch_jdk_env_index=$((sdkman_switch_jdk_env_index + 1))
done

sdkman_switch_jdk_env_post_parse_fingerprint="$(
  sdkman_switch_jdk_file_fingerprint "$sdkman_switch_jdk_env_rc"
)" || sdkman_switch_jdk_env_post_parse_fingerprint=''
if [[ -z "$sdkman_switch_jdk_env_post_parse_fingerprint" || \
      "$sdkman_switch_jdk_env_post_parse_fingerprint" != \
        "$sdkman_switch_jdk_env_rc_fingerprint" ]]; then
  printf 'The project .sdkmanrc changed while it was being read.\n' >&2
  exit 1
fi

# SDKMAN must never re-read a pathname after validation.  The runner applies
# these indexed, validated arrays directly below instead of calling
# `sdk env install`, whose implementation opens .sdkmanrc again.
sdkman_switch_jdk_install_cleanup_traps

sdkman_switch_jdk_env_root="${SDKMAN_DIR:-${HOME:?HOME is not set}/.sdkman}"
sdkman_switch_jdk_env_init="$sdkman_switch_jdk_env_root/bin/sdkman-init.sh"
if [[ ! -r "$sdkman_switch_jdk_env_init" ]]; then
  printf 'SDKMAN init script is not readable: %s\n' \
    "$sdkman_switch_jdk_env_init" >&2
  exit 1
fi

unset SDKMAN_ENV
export SDKMAN_OLD_PWD="$sdkman_switch_jdk_env_project_pwd"
# shellcheck source=/dev/null
source "$sdkman_switch_jdk_env_init"

if ! type sdk >/dev/null 2>&1; then
  printf 'SDKMAN did not define the sdk command.\n' >&2
  exit 1
fi

sdkman_switch_jdk_env_candidates_dir="${SDKMAN_CANDIDATES_DIR:?SDKMAN_CANDIDATES_DIR is not set}"
if ! sdkman_switch_jdk_acquire_lock run-sdkman-env; then
  exit 1
fi

sdkman_switch_jdk_env_before_states=()
sdkman_switch_jdk_env_owned_states=()
sdkman_switch_jdk_env_authorized=()
sdkman_switch_jdk_env_index=0
while (( sdkman_switch_jdk_env_index < ${#sdkman_switch_jdk_env_candidates[@]} )); do
  sdkman_switch_jdk_env_candidate="${sdkman_switch_jdk_env_candidates[$sdkman_switch_jdk_env_index]}"
  sdkman_switch_jdk_env_version="${sdkman_switch_jdk_env_versions[$sdkman_switch_jdk_env_index]}"
  sdkman_switch_jdk_env_current="$sdkman_switch_jdk_env_candidates_dir/$sdkman_switch_jdk_env_candidate/current"
  sdkman_switch_jdk_env_before="$(
    sdkman_switch_jdk_default_state "$sdkman_switch_jdk_env_current"
  )"
  if [[ "$sdkman_switch_jdk_env_before" == "unsupported" ]]; then
    printf 'Refusing to continue: SDKMAN %s current is not a symlink: %s\n' \
      "$sdkman_switch_jdk_env_candidate" "$sdkman_switch_jdk_env_current" >&2
    exit 1
  fi
  sdkman_switch_jdk_env_before_states+=("$sdkman_switch_jdk_env_before")
  sdkman_switch_jdk_env_owned_states+=("$(
    sdkman_switch_jdk_target_state "$sdkman_switch_jdk_env_version"
  )")

  sdkman_switch_jdk_env_is_authorized=0
  sdkman_switch_jdk_env_other=0
  while (( sdkman_switch_jdk_env_other < ${#sdkman_switch_jdk_env_allowed_candidates[@]} )); do
    if [[ "${sdkman_switch_jdk_env_allowed_candidates[$sdkman_switch_jdk_env_other]}" == \
          "$sdkman_switch_jdk_env_candidate" ]]; then
      sdkman_switch_jdk_env_is_authorized=1
      break
    fi
    sdkman_switch_jdk_env_other=$((sdkman_switch_jdk_env_other + 1))
  done
  if (( sdkman_switch_jdk_env_is_authorized != 0 )) && \
     [[ "$sdkman_switch_jdk_env_before" != "absent" ]]; then
    printf 'Default authorization requires an initially absent current symlink: %s\n' \
      "$sdkman_switch_jdk_env_candidate" >&2
    exit 2
  fi
  sdkman_switch_jdk_env_authorized+=("$sdkman_switch_jdk_env_is_authorized")
  sdkman_switch_jdk_env_index=$((sdkman_switch_jdk_env_index + 1))
done

sdkman_switch_jdk_env_reconcile_status=0
sdkman_switch_jdk_reconcile_environment_defaults() {
  local index=0
  local candidate
  local current
  local before
  local owned
  local after
  local final

  while (( index < ${#sdkman_switch_jdk_env_candidates[@]} )); do
    candidate="${sdkman_switch_jdk_env_candidates[$index]}"
    current="$sdkman_switch_jdk_env_candidates_dir/$candidate/current"
    before="${sdkman_switch_jdk_env_before_states[$index]}"
    owned="${sdkman_switch_jdk_env_owned_states[$index]}"
    after=''
    if ! after="$(sdkman_switch_jdk_default_state "$current")"; then
      sdkman_switch_jdk_env_reconcile_status=1
    elif [[ "$after" == "unsupported" ]]; then
      printf 'SDKMAN %s current became a non-symlink; refusing payload execution.\n' \
        "$candidate" >&2
      sdkman_switch_jdk_env_reconcile_status=1
    elif [[ "${sdkman_switch_jdk_env_authorized[$index]}" == 1 ]]; then
      if [[ "$after" != "$before" && "$after" != "$owned" ]]; then
        printf 'SDKMAN %s default drifted after the SDKMAN operation.\n' \
          "$candidate" >&2
        sdkman_switch_jdk_env_reconcile_status=1
      fi
    elif [[ "$after" != "$before" ]] && \
         ! sdkman_switch_jdk_restore_default "$current" "$before" "$owned"; then
      printf 'Could not restore the SDKMAN %s default safely.\n' \
        "$candidate" >&2
      sdkman_switch_jdk_env_reconcile_status=1
    fi
    index=$((index + 1))
  done

  index=0
  while (( index < ${#sdkman_switch_jdk_env_candidates[@]} )); do
    candidate="${sdkman_switch_jdk_env_candidates[$index]}"
    current="$sdkman_switch_jdk_env_candidates_dir/$candidate/current"
    final=''
    if ! final="$(sdkman_switch_jdk_default_state "$current")"; then
      sdkman_switch_jdk_env_reconcile_status=1
    elif [[ "${sdkman_switch_jdk_env_authorized[$index]}" == 1 ]]; then
      if [[ "$final" != "${sdkman_switch_jdk_env_before_states[$index]}" && \
            "$final" != "${sdkman_switch_jdk_env_owned_states[$index]}" ]]; then
        sdkman_switch_jdk_env_reconcile_status=1
      fi
    elif [[ "$final" != "${sdkman_switch_jdk_env_before_states[$index]}" ]]; then
      sdkman_switch_jdk_env_reconcile_status=1
    fi
    index=$((index + 1))
  done

  (( sdkman_switch_jdk_env_reconcile_status == 0 ))
}

if ! sdkman_switch_jdk_register_reconcile_callback \
    sdkman_switch_jdk_reconcile_environment_defaults; then
  exit 1
fi

# Apply only the entries that were parsed and validated above.  In particular,
# do not call `sdk env install`: it opens .sdkmanrc itself and would create a
# second, mutable source of candidate names and versions.
sdkman_switch_jdk_env_sdk_status=0
sdkman_switch_jdk_env_index=0
while (( sdkman_switch_jdk_env_index < ${#sdkman_switch_jdk_env_candidates[@]} )); do
  sdkman_switch_jdk_env_candidate="${sdkman_switch_jdk_env_candidates[$sdkman_switch_jdk_env_index]}"
  sdkman_switch_jdk_env_version="${sdkman_switch_jdk_env_versions[$sdkman_switch_jdk_env_index]}"
  set +e
  USE=n sdk install "$sdkman_switch_jdk_env_candidate" "$sdkman_switch_jdk_env_version" <<< 'n'
  sdkman_switch_jdk_env_sdk_status=$?
  set -e
  if (( sdkman_switch_jdk_env_sdk_status != 0 )); then
    break
  fi
  sdkman_switch_jdk_env_index=$((sdkman_switch_jdk_env_index + 1))
done

if (( sdkman_switch_jdk_env_sdk_status == 0 )); then
  sdkman_switch_jdk_env_index=0
  while (( sdkman_switch_jdk_env_index < ${#sdkman_switch_jdk_env_candidates[@]} )); do
    sdkman_switch_jdk_env_candidate="${sdkman_switch_jdk_env_candidates[$sdkman_switch_jdk_env_index]}"
    sdkman_switch_jdk_env_version="${sdkman_switch_jdk_env_versions[$sdkman_switch_jdk_env_index]}"
    set +e
    sdk use "$sdkman_switch_jdk_env_candidate" "$sdkman_switch_jdk_env_version"
    sdkman_switch_jdk_env_sdk_status=$?
    set -e
    if (( sdkman_switch_jdk_env_sdk_status != 0 )); then
      break
    fi
    sdkman_switch_jdk_env_index=$((sdkman_switch_jdk_env_index + 1))
  done
fi
unset SDKMAN_ENV

sdkman_switch_jdk_env_rc_changed=0
if [[ ! -f "$sdkman_switch_jdk_env_rc" || -L "$sdkman_switch_jdk_env_rc" || \
      ! -O "$sdkman_switch_jdk_env_rc" ]] || \
   ! sdkman_switch_jdk_env_post_operation_fingerprint="$(
     sdkman_switch_jdk_file_fingerprint "$sdkman_switch_jdk_env_rc"
   )" || \
   [[ "$sdkman_switch_jdk_env_post_operation_fingerprint" != \
        "$sdkman_switch_jdk_env_rc_fingerprint" ]]; then
  printf 'The project .sdkmanrc changed while the SDKMAN environment was being activated.\n' >&2
  sdkman_switch_jdk_env_rc_changed=1
fi

sdkman_switch_jdk_env_requested_status="$sdkman_switch_jdk_env_sdk_status"
if (( sdkman_switch_jdk_env_rc_changed != 0 )); then
  sdkman_switch_jdk_env_requested_status=1
fi
set +e
sdkman_switch_jdk_finish_operation "$sdkman_switch_jdk_env_requested_status"
sdkman_switch_jdk_env_finish_status=$?
set -e

if (( sdkman_switch_jdk_deferred_signal_status != 0 )); then
  exit "$sdkman_switch_jdk_env_finish_status"
fi
if (( sdkman_switch_jdk_env_reconcile_status != 0 )); then
  printf 'SDKMAN defaults could not be reconciled safely; the command was not run.\n' >&2
  exit 1
fi
if (( sdkman_switch_jdk_env_finish_status != sdkman_switch_jdk_env_requested_status )); then
  exit 1
fi
if (( sdkman_switch_jdk_env_rc_changed != 0 )); then
  exit 1
fi
if (( sdkman_switch_jdk_env_sdk_status != 0 )); then
  printf 'SDKMAN failed to activate the project environment (status %d); the command was not run.\n' \
    "$sdkman_switch_jdk_env_sdk_status" >&2
  exit "$sdkman_switch_jdk_env_sdk_status"
fi

sdkman_switch_jdk_env_index=0
while (( sdkman_switch_jdk_env_index < ${#sdkman_switch_jdk_env_candidates[@]} )); do
  if [[ "${sdkman_switch_jdk_env_candidates[$sdkman_switch_jdk_env_index]}" == "java" ]]; then
    sdkman_switch_jdk_env_java_home="$sdkman_switch_jdk_env_candidates_dir/java/${sdkman_switch_jdk_env_versions[$sdkman_switch_jdk_env_index]}"
    sdkman_switch_jdk_env_expected_java="$sdkman_switch_jdk_env_java_home/bin/java"
    sdkman_switch_jdk_env_actual_java="$(command -v java 2>/dev/null || true)"
    if [[ "${JAVA_HOME-}" != "$sdkman_switch_jdk_env_java_home" || \
          "$sdkman_switch_jdk_env_actual_java" != "$sdkman_switch_jdk_env_expected_java" ]]; then
      printf 'Active Java does not match the project SDKMAN environment.\n' >&2
      printf 'Expected: %s\nActual:   %s\n' \
        "$sdkman_switch_jdk_env_expected_java" \
        "${sdkman_switch_jdk_env_actual_java:-absent}" >&2
      exit 1
    fi
    if ! java -version >&2; then
      printf 'Project Java could not report its version.\n' >&2
      exit 1
    fi
    printf 'java: %s\n' "$sdkman_switch_jdk_env_actual_java" >&2
    break
  fi
  sdkman_switch_jdk_env_index=$((sdkman_switch_jdk_env_index + 1))
done

sdkman_switch_jdk_clear_cleanup_traps
exec "${sdkman_switch_jdk_env_payload[@]}"
