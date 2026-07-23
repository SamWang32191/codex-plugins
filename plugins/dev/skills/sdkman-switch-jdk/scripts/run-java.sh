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

if [[ -n "${SDKMAN_DIR:-}" ]]; then
  sdkman_switch_jdk_run_root="$SDKMAN_DIR"
elif [[ -n "${HOME:-}" ]]; then
  sdkman_switch_jdk_run_root="$HOME/.sdkman"
else
  printf 'SDKMAN_DIR and HOME are both unset.\n' >&2
  exit 1
fi
case "$sdkman_switch_jdk_run_root" in
  /*) ;;
  *)
    printf 'SDKMAN_DIR must be an absolute path: %s\n' \
      "$sdkman_switch_jdk_run_root" >&2
    exit 1
    ;;
esac
if ! sdkman_switch_jdk_run_root="$(
  cd "$sdkman_switch_jdk_run_root" 2>/dev/null && pwd -P
)"; then
  printf 'SDKMAN directory is not accessible: %s\n' \
    "$sdkman_switch_jdk_run_root" >&2
  exit 1
fi

sdkman_switch_jdk_run_java_dir="$sdkman_switch_jdk_run_root/candidates/java"
sdkman_switch_jdk_run_target="$sdkman_switch_jdk_run_java_dir/$sdkman_switch_jdk_run_identifier"
sdkman_switch_jdk_run_expected="$sdkman_switch_jdk_run_target/bin/java"

if [[ ! -d "$sdkman_switch_jdk_run_target" || \
      ! -f "$sdkman_switch_jdk_run_expected" || \
      ! -x "$sdkman_switch_jdk_run_expected" ]]; then
  printf 'Java is not installed or is incomplete: %s\n' \
    "$sdkman_switch_jdk_run_identifier" >&2
  exit 1
fi

export JAVA_HOME="$sdkman_switch_jdk_run_target"
sdkman_switch_jdk_run_original_path="${PATH-}"
if [[ -n "$sdkman_switch_jdk_run_original_path" ]]; then
  export PATH="$JAVA_HOME/bin:$sdkman_switch_jdk_run_original_path"
else
  export PATH="$JAVA_HOME/bin"
fi

hash -r
sdkman_switch_jdk_run_java="$(command -v java)"
if [[ "$sdkman_switch_jdk_run_java" != "$sdkman_switch_jdk_run_expected" ]]; then
  printf 'Active java does not match the requested SDKMAN identifier.\n' >&2
  printf 'Expected: %s\nActual:   %s\n' \
    "$sdkman_switch_jdk_run_expected" "$sdkman_switch_jdk_run_java" >&2
  exit 1
fi

"$sdkman_switch_jdk_run_expected" -version >&2
printf 'java: %s\n' "$sdkman_switch_jdk_run_java" >&2
exec -- "$@"
