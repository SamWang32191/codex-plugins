#!/usr/bin/env bash

# Contract tests for the sdkman-switch-jdk shell scripts. The suite only uses
# temporary fake SDKMAN files and commands; it never sources a real SDKMAN
# installation or accesses the network.

set -e -o pipefail

test_root="$(cd "$(dirname "$0")/.." && pwd)"
default_scripts_dir="$test_root/plugins/dev/skills/sdkman-switch-jdk/scripts"
scripts_dir="${SDKMAN_SWITCH_JDK_SCRIPTS_DIR:-$default_scripts_dir}"
if [[ ! -d "$scripts_dir" ]]; then
  printf 'SDKMAN_SWITCH_JDK_SCRIPTS_DIR is not a directory: %s\n' "$scripts_dir" >&2
  exit 1
fi
scripts_dir="$(cd "$scripts_dir" && pwd)"
install_script="$scripts_dir/install-java.sh"
run_script="$scripts_dir/run-java.sh"
full_env_script="$scripts_dir/run-sdkman-env.sh"
if [[ ! -r "$install_script" || ! -r "$run_script" ]]; then
  printf 'Missing SDKMAN switch scripts in: %s\n' "$scripts_dir" >&2
  exit 1
fi

original_path="$PATH"
real_mv="$(command -v mv)"
real_ln="$(command -v ln)"
real_mkdir="$(command -v mkdir)"
scenario_filter="${1:-}"
if [[ $# -gt 1 ]]; then
  printf 'Usage: %s [scenario-name]\n' "${0##*/}" >&2
  exit 2
fi
root_tmp="$(mktemp -d "${TMPDIR:-/tmp}/sdkman-switch-jdk-contract.XXXXXX")"
case_name=''
case_dir=''
case_java_dir=''
case_current=''
case_pwd=''
case_tmp_dir=''
fake_bin=''
shadow_bin=''
last_status=0
scenario_count=0
background_pids=''
live_lock_fixture_dir=''
live_lock_owner_pid=''

register_background_pid() {
  background_pids="${background_pids}${background_pids:+ }$1"
}

stop_background_processes() {
  local background_pid

  for background_pid in $background_pids; do
    if kill -0 "$background_pid" 2>/dev/null; then
      kill "$background_pid" 2>/dev/null || true
    fi
  done
  for background_pid in $background_pids; do
    wait "$background_pid" 2>/dev/null || true
  done
  background_pids=''
}

remove_lock_fixture_dir() {
  local lock_dir="$1"

  rm -f "$lock_dir/pid" "$lock_dir/euid" "$lock_dir/token" "$lock_dir/label"
  rmdir "$lock_dir" 2>/dev/null || true
}

cleanup() {
  local cleanup_status="$?"
  trap - EXIT HUP INT TERM
  stop_background_processes
  if [[ -n "$live_lock_fixture_dir" ]]; then
    remove_lock_fixture_dir "$live_lock_fixture_dir"
  fi
  if [[ -n "$root_tmp" && -d "$root_tmp" ]]; then
    find "$root_tmp" -depth -delete
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf 'FAIL [%s]: %s\n' "${case_name:-setup}" "$*" >&2
  if [[ -n "$case_dir" && -s "$case_dir/stderr" ]]; then
    printf 'captured script stderr:\n' >&2
    sed -n '1,20p' "$case_dir/stderr" >&2
  fi
  if [[ -s "${FAKE_THIRD_WRITER_LOG:-}" ]]; then
    printf 'captured third-writer evidence:\n' >&2
    sed -n '1,20p' "$FAKE_THIRD_WRITER_LOG" >&2
  fi
  if [[ -s "${FAKE_PRE_CAS_WRITER_LOG:-}" ]]; then
    printf 'captured pre-CAS writer evidence:\n' >&2
    sed -n '1,20p' "$FAKE_PRE_CAS_WRITER_LOG" >&2
  fi
  if [[ -n "$case_dir" ]]; then
    printf 'failed case directory (removed on exit): %s\n' "$case_dir" >&2
  fi
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [[ "$expected" != "$actual" ]]; then
    fail "$message (expected <$expected>, got <$actual>)"
  fi
}

assert_status() {
  assert_eq "$1" "$last_status" "$2"
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  local message="$3"
  if [[ ! -f "$file" ]] || ! grep -F "$needle" "$file" >/dev/null 2>&1; then
    fail "$message (missing <$needle> in $file)"
  fi
}

assert_file_not_contains() {
  local file="$1"
  local needle="$2"
  local message="$3"
  if [[ -f "$file" ]] && grep -F "$needle" "$file" >/dev/null 2>&1; then
    fail "$message (unexpected <$needle> in $file)"
  fi
}

assert_file_empty() {
  local file="$1"
  local message="$2"
  if [[ -s "$file" ]]; then
    fail "$message (file is not empty: $file)"
  fi
}

assert_file_executable() {
  local file="$1"
  local message="$2"
  if [[ ! -x "$file" ]]; then
    fail "$message (not executable: $file)"
  fi
}

hex_stream() {
  LC_ALL=C od -An -v -tx1 | LC_ALL=C tr -d '[:space:]'
}

raw_target_hex() {
  printf '%s' "$1" | hex_stream
}

link_target_hex() {
  readlink -n "$1" | hex_stream
}

assert_link_target_raw() {
  local expected="$1"
  local link="$2"
  local message="$3"
  assert_eq "$(raw_target_hex "$expected")" "$(link_target_hex "$link")" "$message"
}

assert_path_absent() {
  local path="$1"
  local message="$2"
  if [[ -e "$path" || -L "$path" ]]; then
    fail "$message (unexpected path: $path)"
  fi
}

default_state() {
  if [[ -L "$case_current" ]]; then
    printf 'link:%s\n' "$(readlink "$case_current")"
  elif [[ -e "$case_current" ]]; then
    printf 'unsupported\n'
  else
    printf 'absent\n'
  fi
}

candidate_current_path() {
  local candidate="$1"

  printf '%s/%s/current\n' "$SDKMAN_CANDIDATES_DIR" "$candidate"
}

candidate_default_state() {
  local candidate="$1"
  local current

  current="$(candidate_current_path "$candidate")"
  if [[ -L "$current" ]]; then
    printf 'link:%s\n' "$(readlink "$current")"
  elif [[ -e "$current" ]]; then
    printf 'unsupported\n'
  else
    printf 'absent\n'
  fi
}

assert_candidate_default_state() {
  local candidate="$1"
  local expected="$2"
  local message="$3"

  assert_eq "$expected" "$(candidate_default_state "$candidate")" "$message"
}

assert_default_state() {
  local expected="$1"
  local message="$2"
  assert_eq "$expected" "$(default_state)" "$message"
}

create_java_candidate() {
  local candidate="$1"
  local interpreter="${2:-/usr/bin/env bash}"
  mkdir -p "$candidate/bin"
  {
    printf '#!%s\n' "$interpreter"
    printf '%s\n' 'log="${FAKE_JAVA_LOG:?}"'
    printf '%s\n' 'printf "java JAVA_HOME=<%s>\n" "${JAVA_HOME-}" >> "$log"'
    printf '%s\n' 'printf "java argc=%s\n" "$#" >> "$log"'
    printf '%s\n' 'java_index=0'
    printf '%s\n' 'for java_arg in "$@"; do'
    printf '%s\n' '  printf "java arg[%s]=<%s>\n" "$java_index" "$java_arg" >> "$log"'
    printf '%s\n' '  java_index=$((java_index + 1))'
    printf '%s\n' 'done'
    printf '%s\n' 'if [[ "${1-}" == "-version" ]]; then'
    printf '%s\n' '  printf "%s\n" "fake-java version" >&2'
    printf '%s\n' 'fi'
    printf '%s\n' 'exit "${FAKE_JAVA_STATUS:-0}"'
  } > "$candidate/bin/java"
  chmod +x "$candidate/bin/java"
}

create_incomplete_candidate() {
  local candidate="$1"
  mkdir -p "$candidate/bin"
}

write_sdkmanrc() {
  # The environment runner explicitly applies each validated entry with
  # `sdk use`; model SDKMAN's current-link mutation for those invocations.
  export FAKE_SDK_USE_MUTATE=target_rel
  export FAKE_SDK_ENV_DIRECT=yes
  : > "$case_dir/.sdkmanrc"
  while [[ $# -gt 0 ]]; do
    printf '%s\n' "$1" >> "$case_dir/.sdkmanrc"
    shift
  done
}

set_full_env_operation_raw_target() {
  local candidate="$1"
  local raw_target="$2"

  printf '%s %s\n' "$candidate" "$raw_target" >> "$FAKE_SDK_ENV_OPERATION_FILE"
}

write_fake_init() {
  local init_file="$SDKMAN_DIR/bin/sdkman-init.sh"
  {
    printf '%s\n' '# fake SDKMAN init used by sdkman-switch-jdk-contract.sh'
    printf '%s\n' 'printf "init SDKMAN_ENV=<%s> SDKMAN_OLD_PWD=<%s>\n" "${SDKMAN_ENV-<unset>}" "${SDKMAN_OLD_PWD-<unset>}" >> "${FAKE_INIT_LOG:?}"'
    printf '%s\n' 'fake_sdk_write_candidate() {'
    printf '%s\n' '  local fake_candidate="$1"'
    printf '%s\n' '  mkdir -p "$fake_candidate/bin"'
    printf '%s\n' '  {'
    printf '%s\n' '    printf "%s\n" "#!/usr/bin/env bash"'
    printf '%s\n' '    printf "%s\n" '\''log="${FAKE_JAVA_LOG:?}"'\'''
    printf '%s\n' '    printf "%s\n" '\''printf "java JAVA_HOME=<%s>\\n" "${JAVA_HOME-}" >> "$log"'\'''
    printf '%s\n' '    printf "%s\n" '\''printf "java argc=%s\\n" "$#" >> "$log"'\'''
    printf '%s\n' '    printf "%s\n" '\''java_index=0'\'''
    printf '%s\n' '    printf "%s\n" '\''for java_arg in "$@"; do'\'''
    printf '%s\n' '    printf "%s\n" '\''  printf "java arg[%s]=<%s>\\n" "$java_index" "$java_arg" >> "$log"'\'''
    printf '%s\n' '    printf "%s\n" '\''  java_index=$((java_index + 1))'\'''
    printf '%s\n' '    printf "%s\n" '\''done'\'''
    printf '%s\n' '    printf "%s\n" '\''if [[ "${1-}" == "-version" ]]; then'\'''
    printf '%s\n' '    printf "%s\n" '\''  printf "%s\\n" "fake-java version" >&2'\'''
    printf '%s\n' '    printf "%s\n" '\''fi'\'''
    printf '%s\n' '    printf "%s\n" '\''exit "${FAKE_JAVA_STATUS:-0}"'\'''
    printf '%s\n' '  } > "$fake_candidate/bin/java"'
    printf '%s\n' '  chmod +x "$fake_candidate/bin/java"'
    printf '%s\n' '}'
    printf '%s\n' 'fake_sdk_activate_candidate() {'
    printf '%s\n' '  local fake_candidate_name="$1"'
    printf '%s\n' '  local fake_identifier="$2"'
    printf '%s\n' '  if [[ "$fake_candidate_name" != java ]]; then return 0; fi'
    printf '%s\n' '  fake_java_home="${SDKMAN_CANDIDATES_DIR}/java/${fake_identifier}"'
    printf '%s\n' '  [[ -x "$fake_java_home/bin/java" ]] || fake_sdk_write_candidate "$fake_java_home" || return $?'
    printf '%s\n' '  export JAVA_HOME="$fake_java_home"'
    printf '%s\n' '  export PATH="$JAVA_HOME/bin:$PATH"'
    printf '%s\n' '}'
    printf '%s\n' 'fake_sdk_set_candidate_current() {'
    printf '%s\n' '  local fake_candidate="$1"'
    printf '%s\n' '  local fake_target="$2"'
    printf '%s\n' '  local fake_current="${SDKMAN_CANDIDATES_DIR}/${fake_candidate}/current"'
    printf '%s\n' '  mkdir -p "${SDKMAN_CANDIDATES_DIR}/${fake_candidate}"'
    printf '%s\n' '  if [[ -L "$fake_current" || -e "$fake_current" ]]; then unlink "$fake_current"; fi'
    printf '%s\n' '  ln -s -- "$fake_target" "$fake_current"'
    printf '%s\n' '}'
    printf '%s\n' 'fake_sdk_set_current() {'
    printf '%s\n' '  fake_sdk_set_candidate_current java "$1"'
    printf '%s\n' '}'
    printf '%s\n' 'fake_sdk_env_operation_target() {'
    printf '%s\n' '  local fake_candidate="$1"'
    printf '%s\n' '  local fake_identifier="$2"'
    printf '%s\n' '  local fake_config_candidate'
    printf '%s\n' '  local fake_config_target'
    printf '%s\n' '  fake_sdk_env_target="$fake_identifier"'
    printf '%s\n' '  [[ -n "${FAKE_SDK_ENV_OPERATION_FILE:-}" && -f "$FAKE_SDK_ENV_OPERATION_FILE" ]] || return 0'
    printf '%s\n' '  while read -r fake_config_candidate fake_config_target; do'
    printf '%s\n' '    if [[ "$fake_config_candidate" == "$fake_candidate" ]]; then fake_sdk_env_target="$fake_config_target"; return 0; fi'
    printf '%s\n' '  done < "$FAKE_SDK_ENV_OPERATION_FILE"'
    printf '%s\n' '}'
    printf '%s\n' 'fake_sdk_maybe_replace_project_rc() {'
    printf '%s\n' '  if [[ -z "${FAKE_SDK_ENV_REPLACEMENT:-}" || -n "${fake_sdk_replaced_project_rc:-}" ]]; then return 0; fi'
    printf '%s\n' '  "${FAKE_REAL_MV:?}" -f "$FAKE_SDK_ENV_REPLACEMENT" "${FAKE_PROJECT_SDKMANRC:?}" || return $?'
    printf '%s\n' '  fake_sdk_replaced_project_rc=1'
    printf '%s\n' '  printf "sdkmanrc-replace pid=<%s> cwd=<%s> destination=<%s>\\n" "$$" "$PWD" "$FAKE_PROJECT_SDKMANRC" >> "${FAKE_SDK_ENV_REPLACE_LOG:?}"'
    printf '%s\n' '}'
    # This models the forbidden second-read behavior for the TOCTOU mutation
    # proof. The production runner must never select this fake SDK command.
    printf '%s\n' 'fake_sdk_env_install() {'
    printf '%s\n' '  local fake_candidate'
    printf '%s\n' '  local fake_identifier'
    printf '%s\n' '  local fake_java_identifier=""'
    printf '%s\n' '  [[ -f .sdkmanrc ]] || return 65'
    printf '%s\n' '  if [[ -n "${FAKE_SDK_ENV_REPLACEMENT:-}" ]]; then'
    printf '%s\n' '    "${FAKE_REAL_MV:?}" -f "$FAKE_SDK_ENV_REPLACEMENT" "${FAKE_PROJECT_SDKMANRC:?}" || return $?'
    printf '%s\n' '    printf "sdkmanrc-replace pid=<%s> cwd=<%s> destination=<%s>\\n" "$$" "$PWD" "$FAKE_PROJECT_SDKMANRC" >> "${FAKE_SDK_ENV_REPLACE_LOG:?}"'
    printf '%s\n' '  fi'
    printf '%s\n' '  while IFS="=" read -r fake_candidate fake_identifier; do'
    printf '%s\n' '    [[ -n "$fake_candidate" && -n "$fake_identifier" ]] || continue'
    printf '%s\n' '    printf "sdk env candidate=<%s> version=<%s>\\n" "$fake_candidate" "$fake_identifier" >> "${FAKE_SDK_LOG:?}"'
    printf '%s\n' '    fake_sdk_env_operation_target "$fake_candidate" "$fake_identifier"'
    printf '%s\n' '    fake_sdk_set_candidate_current "$fake_candidate" "$fake_sdk_env_target" || return $?'
    printf '%s\n' '    if [[ "$fake_candidate" == java ]]; then fake_java_identifier="$fake_identifier"; fi'
    printf '%s\n' '  done < .sdkmanrc'
    printf '%s\n' '  if [[ -n "$fake_java_identifier" ]]; then'
    printf '%s\n' '    fake_java_home="${SDKMAN_CANDIDATES_DIR}/java/${fake_java_identifier}"'
    printf '%s\n' '    [[ -x "$fake_java_home/bin/java" ]] || fake_sdk_write_candidate "$fake_java_home"'
    printf '%s\n' '    export JAVA_HOME="$fake_java_home"'
    printf '%s\n' '    export PATH="$JAVA_HOME/bin:$PATH"'
    printf '%s\n' '  fi'
    printf '%s\n' '  fake_sdk_signal_after_mutation || return $?'
    printf '%s\n' '  fake_sdk_run_third_writer || return $?'
    printf '%s\n' '  return "${FAKE_SDK_ENV_INSTALL_STATUS:-0}"'
    printf '%s\n' '}'
    printf '%s\n' 'fake_sdk_run_third_writer() {'
    printf '%s\n' '  local fake_operation_candidate="${1-}"'
    printf '%s\n' '  local fake_operation_action="${2-}"'
    printf '%s\n' '  local fake_writer_pid'
    printf '%s\n' '  local fake_writer_candidate="${FAKE_SDK_THIRD_WRITER_CANDIDATE:-java}"'
    printf '%s\n' '  local fake_writer_current="${SDKMAN_CANDIDATES_DIR}/${fake_writer_candidate}/current"'
    printf '%s\n' '  if [[ -z "${FAKE_SDK_THIRD_WRITER_TARGET:-}" ]]; then return 0; fi'
    printf '%s\n' '  if [[ -n "${FAKE_SDK_THIRD_WRITER_AFTER_CANDIDATE:-}" && "$fake_operation_candidate" != "$FAKE_SDK_THIRD_WRITER_AFTER_CANDIDATE" ]]; then return 0; fi'
    printf '%s\n' '  if [[ -n "${FAKE_SDK_THIRD_WRITER_AFTER_ACTION:-}" && "$fake_operation_action" != "$FAKE_SDK_THIRD_WRITER_AFTER_ACTION" ]]; then return 0; fi'
    printf '%s\n' '  "$BASH" -c '\''set -e'
    printf '%s\n' '    fake_writer_current="${SDKMAN_CANDIDATES_DIR}/${FAKE_SDK_THIRD_WRITER_CANDIDATE:-java}/current"'
    printf '%s\n' '    mkdir -p "$(dirname "$fake_writer_current")"'
    printf '%s\n' '    if [[ -L "$fake_writer_current" || -e "$fake_writer_current" ]]; then unlink "$fake_writer_current"; fi'
    printf '%s\n' '    ln -s -- "$FAKE_SDK_THIRD_WRITER_TARGET" "$fake_writer_current"'
    printf '%s\n' '    printf "third-writer pid=<%s> candidate=<%s> target=<%s>\\n" "$$" "${FAKE_SDK_THIRD_WRITER_CANDIDATE:-java}" "$FAKE_SDK_THIRD_WRITER_TARGET" >> "${FAKE_THIRD_WRITER_LOG:?}"'\'' &'
    printf '%s\n' '  fake_writer_pid=$!'
    printf '%s\n' '  wait "$fake_writer_pid" || return $?'
    printf '%s\n' '  printf "sdk third-writer waited-pid=<%s> candidate=<%s> target=<%s>\\n" "$fake_writer_pid" "$fake_writer_candidate" "$FAKE_SDK_THIRD_WRITER_TARGET" >> "${FAKE_SDK_LOG:?}"'
    printf '%s\n' '}'
    printf '%s\n' 'fake_sdk_signal_after_mutation() {'
    printf '%s\n' '  local fake_operation_candidate="${1-}"'
    printf '%s\n' '  local fake_operation_action="${2-}"'
    printf '%s\n' '  if [[ -z "${FAKE_SDK_SIGNAL_AFTER_MUTATION:-}" ]]; then return 0; fi'
    printf '%s\n' '  if [[ -n "${FAKE_SDK_SIGNAL_AFTER_CANDIDATE:-}" && "$fake_operation_candidate" != "$FAKE_SDK_SIGNAL_AFTER_CANDIDATE" ]]; then return 0; fi'
    printf '%s\n' '  if [[ -n "${FAKE_SDK_SIGNAL_AFTER_ACTION:-}" && "$fake_operation_action" != "$FAKE_SDK_SIGNAL_AFTER_ACTION" ]]; then return 0; fi'
    printf '%s\n' '  printf "sdk-signal pid=<%s> signal=<%s>\\n" "$$" "$FAKE_SDK_SIGNAL_AFTER_MUTATION" >> "${FAKE_SDK_SIGNAL_LOG:?}"'
    printf '%s\n' '  case "$FAKE_SDK_SIGNAL_AFTER_MUTATION" in'
    printf '%s\n' '    TERM) kill -TERM "$$" ;;'
    printf '%s\n' '    *) return 97 ;;'
    printf '%s\n' '  esac'
    printf '%s\n' '}'
    printf '%s\n' 'sdk() {'
    printf '%s\n' '  {'
    printf '%s\n' '    printf "sdk pid=<%s>\\n" "$$"'
    printf '%s\n' '    printf "sdk USE=<%s>\\n" "${USE-<unset>}"'
    printf '%s\n' '    printf "sdk argc=%s\\n" "$#"'
    printf '%s\n' '    sdk_index=0'
    printf '%s\n' '    for sdk_arg in "$@"; do'
    printf '%s\n' '      printf "sdk arg[%s]=<%s>\\n" "$sdk_index" "$sdk_arg"'
    printf '%s\n' '      sdk_index=$((sdk_index + 1))'
    printf '%s\n' '    done'
    printf '%s\n' '  } >> "${FAKE_SDK_LOG:?}"'
    printf '%s\n' '  case "${1-}" in'
    printf '%s\n' '    install)'
    printf '%s\n' '      fake_candidate_name="${2-}"'
    printf '%s\n' '      fake_identifier="${3-}"'
    printf '%s\n' '      fake_candidate="${SDKMAN_CANDIDATES_DIR}/${fake_candidate_name}/${fake_identifier}"'
    printf '%s\n' '      fake_install_answer="<none>"'
    printf '%s\n' '      if IFS= read -r fake_install_answer; then :; fi'
    printf '%s\n' '      printf "sdk stdin=<%s>\\n" "$fake_install_answer" >> "${FAKE_SDK_LOG:?}"'
    printf '%s\n' '      fake_sdk_maybe_replace_project_rc || return $?'
    printf '%s\n' '      if [[ "${FAKE_SDK_INSTALL_CREATE:-yes}" == yes ]]; then fake_sdk_write_candidate "$fake_candidate"; fi'
    printf '%s\n' '      case "${FAKE_SDK_INSTALL_MUTATE:-none}" in'
    printf '%s\n' '        target_abs) fake_sdk_set_candidate_current "$fake_candidate_name" "$fake_candidate" ;;'
    printf '%s\n' '        target_rel) fake_sdk_set_candidate_current "$fake_candidate_name" "$fake_identifier" ;;'
    printf '%s\n' '        none) : ;;'
    printf '%s\n' '        *) printf "unknown install mutation: %s\\n" "${FAKE_SDK_INSTALL_MUTATE}" >&2; return 99 ;;'
    printf '%s\n' '      esac'
    printf '%s\n' '      fake_sdk_signal_after_mutation "$fake_candidate_name" install || return $?'
    printf '%s\n' '      fake_sdk_run_third_writer "$fake_candidate_name" install || return $?'
    printf '%s\n' '      if [[ -n "${FAKE_SDK_ENV_INSTALL_STATUS:-}" && "${FAKE_SDK_ENV_INSTALL_STATUS}" != 0 ]]; then return "$FAKE_SDK_ENV_INSTALL_STATUS"; fi'
    printf '%s\n' '      return "${FAKE_SDK_INSTALL_STATUS:-0}"'
    printf '%s\n' '      ;;'
    printf '%s\n' '    use)'
    printf '%s\n' '      fake_candidate_name="${2-}"'
    printf '%s\n' '      fake_identifier="${3-}"'
    printf '%s\n' '      fake_candidate="${SDKMAN_CANDIDATES_DIR}/${fake_candidate_name}/${fake_identifier}"'
    printf '%s\n' '      fake_sdk_maybe_replace_project_rc || return $?'
    printf '%s\n' '      case "${FAKE_SDK_USE_MUTATE:-none}" in'
    printf '%s\n' '        target_abs) fake_sdk_set_candidate_current "$fake_candidate_name" "$fake_candidate" ;;'
    printf '%s\n' '        target_rel) fake_sdk_env_operation_target "$fake_candidate_name" "$fake_identifier"; fake_sdk_set_candidate_current "$fake_candidate_name" "$fake_sdk_env_target" ;;'
    printf '%s\n' '        none) : ;;'
    printf '%s\n' '        *) printf "unknown use mutation: %s\\n" "${FAKE_SDK_USE_MUTATE}" >&2; return 98 ;;'
    printf '%s\n' '      esac'
    printf '%s\n' '      if [[ "${FAKE_SDK_ENV_DIRECT:-no}" == yes ]]; then fake_sdk_activate_candidate "$fake_candidate_name" "$fake_identifier" || return $?; fi'
    printf '%s\n' '      fake_sdk_signal_after_mutation "$fake_candidate_name" use || return $?'
    printf '%s\n' '      fake_sdk_run_third_writer "$fake_candidate_name" use || return $?'
    printf '%s\n' '      return "${FAKE_SDK_USE_STATUS:-0}"'
    printf '%s\n' '      ;;'
    printf '%s\n' '    env)'
    printf '%s\n' '      [[ "${2-}" == install ]] || return 64'
    printf '%s\n' '      fake_sdk_env_install'
    printf '%s\n' '      return $?'
    printf '%s\n' '      ;;'
    printf '%s\n' '    *) return 64 ;;'
    printf '%s\n' '  esac'
    printf '%s\n' '}'
  } > "$init_file"
}

write_fake_mv() {
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'log="${FAKE_MV_LOG:?}"'
    printf '%s\n' 'printf "mv argc=%s\\n" "$#" >> "$log"'
    printf '%s\n' 'mv_index=0'
    printf '%s\n' 'for mv_arg in "$@"; do'
    printf '%s\n' '  printf "mv arg[%s]=<%s>\\n" "$mv_index" "$mv_arg" >> "$log"'
    printf '%s\n' '  mv_index=$((mv_index + 1))'
    printf '%s\n' 'done'
    printf '%s\n' 'if [[ "${1-}" == "-fh" && -n "${FAKE_MV_GNU_FALLBACK_WRITER_TARGET:-}" ]]; then'
    printf '%s\n' '  "$BASH" -c '\''set -e'
    printf '%s\n' '    fake_writer_candidate="${FAKE_MV_GNU_FALLBACK_WRITER_CANDIDATE:-java}"'
    printf '%s\n' '    fake_writer_current="${SDKMAN_CANDIDATES_DIR}/${fake_writer_candidate}/current"'
    printf '%s\n' '    printf "gnu-fallback-writer-ready pid=<%s> candidate=<%s>\\n" "$$" "$fake_writer_candidate" > "${FAKE_MV_GNU_FALLBACK_WRITER_MARKER:?}"'
    printf '%s\n' '    if [[ -L "$fake_writer_current" || -e "$fake_writer_current" ]]; then unlink "$fake_writer_current"; fi'
    printf '%s\n' '    ln -s -- "$FAKE_MV_GNU_FALLBACK_WRITER_TARGET" "$fake_writer_current"'
    printf '%s\n' '    printf "gnu-fallback-writer-complete pid=<%s> candidate=<%s> target=<%s>\\n" "$$" "$fake_writer_candidate" "$FAKE_MV_GNU_FALLBACK_WRITER_TARGET" >> "${FAKE_MV_GNU_FALLBACK_WRITER_LOG:?}"'\'' &'
    printf '%s\n' '  fake_mv_writer_pid=$!'
    printf '%s\n' '  wait "$fake_mv_writer_pid" || exit $?'
    printf '%s\n' '  printf "mv gnu-fallback parent-pid=<%s> waited-writer-pid=<%s> target=<%s>\\n" "$$" "$fake_mv_writer_pid" "$FAKE_MV_GNU_FALLBACK_WRITER_TARGET" >> "$log"'
    printf '%s\n' '  exit 64'
    printf '%s\n' 'fi'
    printf '%s\n' 'case "${FAKE_MV_MODE:-bsd}" in'
    printf '%s\n' '  bsd) [[ "${1-}" == "-fh" ]] || exit 66 ;;'
    printf '%s\n' '  gnu) if [[ "${1-}" == "-fh" ]]; then exit 64; fi; [[ "${1-}" == "-Tf" ]] || exit 65 ;;'
    printf '%s\n' '  fail) exit 75 ;;'
    printf '%s\n' '  *) exit 76 ;;'
    printf '%s\n' 'esac'
    printf '%s\n' 'mv_source="${2-}"'
    printf '%s\n' 'mv_destination="${3-}"'
    printf '%s\n' 'if [[ -n "${FAKE_MV_FAIL_DESTINATION:-}" && "$mv_destination" == "$FAKE_MV_FAIL_DESTINATION" ]]; then exit 75; fi'
    printf '%s\n' 'if "${FAKE_REAL_MV:?}" -fh "$mv_source" "$mv_destination" 2>/dev/null; then'
    printf '%s\n' '  :'
    printf '%s\n' 'elif [[ -L "$mv_source" ]] && "${FAKE_REAL_MV:?}" -Tf "$mv_source" "$mv_destination" 2>/dev/null; then'
    printf '%s\n' '  :'
    printf '%s\n' 'else'
    printf '%s\n' '  exit 77'
    printf '%s\n' 'fi'
  } > "$fake_bin/mv"
  chmod +x "$fake_bin/mv"
}

write_fake_ln() {
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'fake_ln_destination=""'
    printf '%s\n' 'for fake_ln_arg in "$@"; do fake_ln_destination="$fake_ln_arg"; done'
    printf '%s\n' 'if "${FAKE_REAL_LN:?}" "$@"; then :; else exit $?; fi'
    printf '%s\n' 'if [[ -z "${FAKE_LN_PRE_CAS_WRITER_TARGET:-}" ]]; then exit 0; fi'
    printf '%s\n' 'case "$fake_ln_destination" in'
    printf '%s\n' '  "${FAKE_RESTORE_TEMP_PREFIX:?}"*/current)'
    printf '%s\n' '    "$BASH" -c '\''set -e'
    printf '%s\n' '      if [[ -L "$FAKE_CURRENT_PATH" || -e "$FAKE_CURRENT_PATH" ]]; then unlink "$FAKE_CURRENT_PATH"; fi'
    printf '%s\n' '      "$FAKE_REAL_LN" -s -- "$FAKE_LN_PRE_CAS_WRITER_TARGET" "$FAKE_CURRENT_PATH"'
    printf '%s\n' '      printf "pre-cas writer pid=<%s> ppid=<%s> target=<%s> destination=<%s>\\n" "$$" "$PPID" "$FAKE_LN_PRE_CAS_WRITER_TARGET" "$1" >> "${FAKE_PRE_CAS_WRITER_LOG:?}"'\'' bash "$fake_ln_destination" &'
    printf '%s\n' '    fake_ln_writer_pid=$!'
    printf '%s\n' '    wait "$fake_ln_writer_pid" || exit $?'
    printf '%s\n' '    printf "ln wrapper pid=<%s> waited pre-cas writer pid=<%s> destination=<%s>\\n" "$$" "$fake_ln_writer_pid" "$fake_ln_destination" >> "${FAKE_PRE_CAS_WRITER_LOG:?}"'
    printf '%s\n' '    ;;'
    printf '%s\n' 'esac'
  } > "$fake_bin/ln"
  chmod +x "$fake_bin/ln"
}

write_fake_mkdir() {
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'fake_mkdir_destination=""'
    printf '%s\n' 'for fake_mkdir_arg in "$@"; do fake_mkdir_destination="$fake_mkdir_arg"; done'
    printf '%s\n' 'printf "mkdir destination=<%s>\\n" "$fake_mkdir_destination" >> "${FAKE_MKDIR_LOG:?}"'
    printf '%s\n' 'if [[ -n "${FAKE_MKDIR_FAIL_STATUS:-}" && "$fake_mkdir_destination" == "${FAKE_MKDIR_FAIL_PATH:-}" ]]; then exit "$FAKE_MKDIR_FAIL_STATUS"; fi'
    printf '%s\n' '"${FAKE_REAL_MKDIR:?}" "$@" || exit $?'
    printf '%s\n' 'if [[ "${FAKE_MKDIR_SIGNAL_LOCK_INIT:-}" != TERM || "$fake_mkdir_destination" != "${FAKE_LOCK_PATH:-}" ]]; then exit 0; fi'
    printf '%s\n' 'if [[ -e "${FAKE_MKDIR_SIGNAL_MARKER:?}" ]]; then exit 0; fi'
    printf '%s\n' 'set -C'
    printf '%s\n' ': > "${FAKE_MKDIR_SIGNAL_MARKER:?}" 2>/dev/null || exit 0'
    printf '%s\n' 'set +C'
    printf '%s\n' 'printf "lock-init-signal pid=<%s> parent=<%s> destination=<%s>\\n" "$$" "$PPID" "$fake_mkdir_destination" >> "${FAKE_MKDIR_SIGNAL_LOG:?}"'
    printf '%s\n' 'kill -TERM "$PPID"'
  } > "$fake_bin/mkdir"
  chmod +x "$fake_bin/mkdir"
}

write_payload() {
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'log="${FAKE_PAYLOAD_LOG:?}"'
    printf '%s\n' 'printf "payload JAVA_HOME=<%s>\\n" "${JAVA_HOME-}" > "$log"'
    printf '%s\n' 'printf "payload PATH=<%s>\\n" "${PATH-}" >> "$log"'
    printf '%s\n' 'printf "payload java=<%s>\\n" "$(command -v java)" >> "$log"'
    printf '%s\n' 'printf "payload argc=%s\\n" "$#" >> "$log"'
    printf '%s\n' 'payload_index=0'
    printf '%s\n' 'for payload_arg in "$@"; do'
    printf '%s\n' '  printf "payload arg[%s]=<%s>\\n" "$payload_index" "$payload_arg" >> "$log"'
    printf '%s\n' '  payload_index=$((payload_index + 1))'
    printf '%s\n' 'done'
    printf '%s\n' 'exit "${FAKE_PAYLOAD_STATUS:-0}"'
  } > "$case_dir/payload"
  chmod +x "$case_dir/payload"
}

write_shadow_java() {
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'printf "%s\\n" shadow-java-called >> "${FAKE_SHADOW_LOG:?}"'
    printf '%s\n' 'exit 0'
  } > "$shadow_bin/java"
  chmod +x "$shadow_bin/java"
}

write_candidate_path_hijack() {
  local candidate="$1"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'printf "%s\\n" candidate-path-mv-called >> "${FAKE_PATH_HIJACK_LOG:?}"'
    printf '%s\n' 'exit 96'
  } > "$candidate/bin/mv"
  chmod +x "$candidate/bin/mv"
}

begin_case() {
  case_name="$1"
  case_dir="$root_tmp/$case_name"
  case_java_dir="$case_dir/candidates/java"
  case_current="$case_java_dir/current"
  case_tmp_dir="$case_dir/tmp"
  fake_bin="$case_dir/fake-bin"
  shadow_bin="$case_dir/shadow-bin"
  mkdir -p "$case_dir/sdkman/bin" "$case_java_dir" "$fake_bin" "$shadow_bin" "$case_dir/home" "$case_tmp_dir"
  case_pwd="$(cd "$case_dir" && pwd)"

  export HOME="$case_dir/home"
  export TMPDIR="$case_tmp_dir"
  export SDKMAN_DIR="$case_dir/sdkman"
  export SDKMAN_CANDIDATES_DIR="$case_dir/candidates"
  export FAKE_CURRENT_PATH="$case_current"
  export FAKE_INIT_LOG="$case_dir/init.log"
  export FAKE_SDK_LOG="$case_dir/sdk.log"
  export FAKE_MV_LOG="$case_dir/mv.log"
  export FAKE_JAVA_LOG="$case_dir/java.log"
  export FAKE_PAYLOAD_LOG="$case_dir/payload.log"
  export FAKE_SHADOW_LOG="$case_dir/shadow.log"
  export FAKE_THIRD_WRITER_LOG="$case_dir/third-writer.log"
  export FAKE_PRE_CAS_WRITER_LOG="$case_dir/pre-cas-writer.log"
  export FAKE_MV_GNU_FALLBACK_WRITER_LOG="$case_dir/gnu-fallback-writer.log"
  export FAKE_MV_GNU_FALLBACK_WRITER_MARKER="$case_dir/gnu-fallback-writer.ready"
  export FAKE_SDK_ENV_REPLACE_LOG="$case_dir/sdkmanrc-replace.log"
  export FAKE_SDK_SIGNAL_LOG="$case_dir/sdk-signal.log"
  export FAKE_PATH_HIJACK_LOG="$case_dir/path-hijack.log"
  export FAKE_SDK_ENV_OPERATION_FILE="$case_dir/env-operation-targets"
  export FAKE_REAL_MV="$real_mv"
  export FAKE_REAL_LN="$real_ln"
  export FAKE_REAL_MKDIR="$real_mkdir"
  export FAKE_MKDIR_SIGNAL_LOG="$case_dir/lock-init-signal.log"
  export FAKE_MKDIR_SIGNAL_MARKER="$case_dir/lock-init-signal.marker"
  export FAKE_MKDIR_LOG="$case_dir/mkdir.log"
  export FAKE_LOCK_PATH="$SDKMAN_CANDIDATES_DIR/.sdkman-switch-jdk.lock"
  export FAKE_RESTORE_TEMP_PREFIX="$case_java_dir/.sdkman-switch-jdk-restore."
  export FAKE_SDK_INSTALL_STATUS=0
  export FAKE_SDK_INSTALL_CREATE=yes
  export FAKE_SDK_INSTALL_MUTATE=none
  unset FAKE_SDK_THIRD_WRITER_TARGET
  unset FAKE_SDK_THIRD_WRITER_CANDIDATE
  unset FAKE_SDK_THIRD_WRITER_AFTER_CANDIDATE
  unset FAKE_SDK_THIRD_WRITER_AFTER_ACTION
  unset FAKE_LN_PRE_CAS_WRITER_TARGET
  unset FAKE_MV_GNU_FALLBACK_WRITER_TARGET
  unset FAKE_MV_GNU_FALLBACK_WRITER_CANDIDATE
  unset FAKE_SDK_ENV_REPLACEMENT
  unset FAKE_PROJECT_SDKMANRC
  unset FAKE_SDK_ENV_DIRECT
  unset FAKE_MKDIR_SIGNAL_LOCK_INIT
  unset FAKE_MKDIR_FAIL_PATH
  unset FAKE_MKDIR_FAIL_STATUS
  unset FAKE_SDK_SIGNAL_AFTER_MUTATION
  unset FAKE_SDK_SIGNAL_AFTER_CANDIDATE
  unset FAKE_SDK_SIGNAL_AFTER_ACTION
  export FAKE_SDK_USE_STATUS=0
  export FAKE_SDK_USE_MUTATE=none
  export FAKE_MV_MODE=bsd
  unset FAKE_MV_FAIL_DESTINATION
  export FAKE_SDK_ENV_INSTALL_STATUS=0
  export FAKE_JAVA_STATUS=0
  export FAKE_PAYLOAD_STATUS=0
  export PATH="$fake_bin:$original_path"

  : > "$FAKE_INIT_LOG"
  : > "$FAKE_SDK_LOG"
  : > "$FAKE_MV_LOG"
  : > "$FAKE_JAVA_LOG"
  : > "$FAKE_PAYLOAD_LOG"
  : > "$FAKE_SHADOW_LOG"
  : > "$FAKE_THIRD_WRITER_LOG"
  : > "$FAKE_PRE_CAS_WRITER_LOG"
  : > "$FAKE_MV_GNU_FALLBACK_WRITER_LOG"
  : > "$FAKE_SDK_ENV_REPLACE_LOG"
  : > "$FAKE_SDK_SIGNAL_LOG"
  : > "$FAKE_PATH_HIJACK_LOG"
  : > "$FAKE_MKDIR_SIGNAL_LOG"
  : > "$FAKE_MKDIR_LOG"
  : > "$FAKE_SDK_ENV_OPERATION_FILE"
  write_fake_init
  write_fake_mv
  write_fake_ln
  write_fake_mkdir
  write_payload
}

set_default() {
  local mode="$1"
  local identifier="$2"
  local raw_target="${3:-$identifier}"
  case "$mode" in
    absolute)
      ln -s -- "$case_java_dir/$identifier" "$case_current"
      ;;
    relative)
      ln -s -- "$raw_target" "$case_current"
      ;;
    absent)
      ;;
    *)
      fail "unknown default mode: $mode"
      ;;
  esac
}

set_candidate_default() {
  local candidate="$1"
  local mode="$2"
  local identifier="$3"
  local raw_target="${4:-$identifier}"
  local current

  current="$(candidate_current_path "$candidate")"
  mkdir -p "$(dirname "$current")"
  case "$mode" in
    absolute)
      ln -s -- "$SDKMAN_CANDIDATES_DIR/$candidate/$identifier" "$current"
      ;;
    relative)
      ln -s -- "$raw_target" "$current"
      ;;
    absent)
      ;;
    *)
      fail "unknown candidate default mode: $mode"
      ;;
  esac
}

run_capture() {
  set +e
  (cd "$case_dir" && "$@") > "$case_dir/stdout" 2> "$case_dir/stderr"
  last_status=$?
  set -e
}

assert_no_restore_temp_dirs() {
  local leftover
  for leftover in "$case_java_dir"/.sdkman-switch-jdk-restore.*; do
    if [[ -e "$leftover" ]]; then
      fail "restore temporary directory remains: $leftover"
    fi
  done
}

assert_third_writer_ran() {
  local expected_target="$1"
  local expected_candidate="${2:-java}"
  local sdk_pid
  local writer_pid

  assert_file_contains "$FAKE_THIRD_WRITER_LOG" 'third-writer pid=<' \
    'third writer records its subprocess PID'
  assert_file_contains "$FAKE_THIRD_WRITER_LOG" "candidate=<$expected_candidate>" \
    'third writer records the candidate it changed'
  assert_file_contains "$FAKE_THIRD_WRITER_LOG" "target=<$expected_target>" \
    'third writer records its target'
  assert_file_contains "$FAKE_SDK_LOG" 'sdk third-writer waited-pid=<' \
    'fake SDK waits for the third writer before returning'
  sdk_pid="$(sed -n 's/^sdk pid=<\([0-9][0-9]*\)>$/\1/p' "$FAKE_SDK_LOG")"
  writer_pid="$(sed -n 's/^third-writer pid=<\([0-9][0-9]*\)> candidate=<.*> target=<.*>$/\1/p' "$FAKE_THIRD_WRITER_LOG")"
  if [[ -z "$sdk_pid" || -z "$writer_pid" ]]; then
    fail 'third writer PID evidence is missing or malformed'
  fi
  if [[ "$sdk_pid" == "$writer_pid" ]]; then
    fail 'third writer did not run in a distinct subprocess'
  fi
}

wait_for_marker() {
  local marker="$1"
  local owner_pid="$2"
  local attempt=0

  while [[ ! -s "$marker" ]]; do
    if ! kill -0 "$owner_pid" 2>/dev/null; then
      fail "marker owner stopped before signalling readiness: $owner_pid"
    fi
    attempt=$((attempt + 1))
    if [[ "$attempt" -gt 100 ]]; then
      fail "timed out waiting for readiness marker: $marker"
    fi
    sleep 0.01
  done
}

write_complete_lock_fixture() {
  local owner_pid="$1"
  local lock_label="$2"
  local owner_euid="$EUID"
  local lock_dir="$SDKMAN_CANDIDATES_DIR/.sdkman-switch-jdk.lock"

  mkdir "$lock_dir"
  printf '%s\n' "$owner_pid" > "$lock_dir/pid"
  printf '%s\n' "$owner_euid" > "$lock_dir/euid"
  printf '%s\n' "${owner_pid}:${owner_euid}:fixture-nonce-a:fixture-nonce-b" > "$lock_dir/token"
  printf '%s\n' "$lock_label" > "$lock_dir/label"
  live_lock_fixture_dir="$lock_dir"
}

snapshot_lock_fixture() {
  local lock_dir="$1"
  local field

  for field in pid euid token label; do
    if [[ ! -f "$lock_dir/$field" ]]; then
      fail "lock metadata is not a regular file: $lock_dir/$field"
    fi
    cp "$lock_dir/$field" "$case_dir/lock-before-$field"
  done
}

assert_lock_fixture_unchanged() {
  local lock_dir="$1"
  local field

  for field in pid euid token label; do
    if [[ ! -f "$lock_dir/$field" ]]; then
      fail "live lock metadata is missing or not regular: $lock_dir/$field"
    fi
    if ! cmp "$case_dir/lock-before-$field" "$lock_dir/$field" >/dev/null 2>&1; then
      fail "live lock metadata changed unexpectedly: $lock_dir/$field"
    fi
  done
}

start_live_lock_owner() {
  local marker="$case_dir/live-lock-owner.ready"

  "$BASH" -c '
    marker="$1"
    printf "live-lock-owner-ready pid=<%s>\\n" "$$" > "$marker"
    trap "exit 0" HUP INT TERM
    while :; do
      read -r -t 1 ignored || :
    done
  ' bash "$marker" &
  live_lock_owner_pid=$!
  register_background_pid "$live_lock_owner_pid"
  wait_for_marker "$marker" "$live_lock_owner_pid"
  if [[ "$live_lock_owner_pid" == "$$" ]] || ! kill -0 "$live_lock_owner_pid" 2>/dev/null; then
    fail 'live lock owner is not a separate live process'
  fi
}

release_live_lock_fixture() {
  local lock_dir="$live_lock_fixture_dir"

  if [[ -n "$live_lock_owner_pid" ]] && kill -0 "$live_lock_owner_pid" 2>/dev/null; then
    kill "$live_lock_owner_pid"
  fi
  if [[ -n "$live_lock_owner_pid" ]]; then
    wait "$live_lock_owner_pid" 2>/dev/null || true
    if kill -0 "$live_lock_owner_pid" 2>/dev/null; then
      fail "live lock owner remained after cleanup: $live_lock_owner_pid"
    fi
  fi
  background_pids=''
  live_lock_owner_pid=''
  remove_lock_fixture_dir "$lock_dir"
  live_lock_fixture_dir=''
  assert_path_absent "$lock_dir" 'live lock fixture is removed after the scenario'
}

assert_pre_cas_writer_ran() {
  local expected_target="$1"
  local wrapper_pid
  local waited_pid
  local writer_pid
  local writer_ppid
  local wrapper_destination
  local writer_destination

  assert_file_contains "$FAKE_PRE_CAS_WRITER_LOG" 'pre-cas writer pid=<' \
    'pre-CAS writer records its subprocess PID'
  assert_file_contains "$FAKE_PRE_CAS_WRITER_LOG" "target=<$expected_target>" \
    'pre-CAS writer records the competing target'
  assert_file_contains "$FAKE_PRE_CAS_WRITER_LOG" 'ln wrapper pid=<' \
    'ln wrapper waits for the pre-CAS writer before returning'
  writer_pid="$(sed -n 's/^pre-cas writer pid=<\([0-9][0-9]*\)> ppid=<.*$/\1/p' "$FAKE_PRE_CAS_WRITER_LOG")"
  writer_ppid="$(sed -n 's/^pre-cas writer pid=<[0-9][0-9]*> ppid=<\([0-9][0-9]*\)> .*$/\1/p' "$FAKE_PRE_CAS_WRITER_LOG")"
  writer_destination="$(sed -n 's/^pre-cas writer .* destination=<\(.*\)>$/\1/p' "$FAKE_PRE_CAS_WRITER_LOG")"
  wrapper_pid="$(sed -n 's/^ln wrapper pid=<\([0-9][0-9]*\)> .*$/\1/p' "$FAKE_PRE_CAS_WRITER_LOG")"
  waited_pid="$(sed -n 's/^ln wrapper .* waited pre-cas writer pid=<\([0-9][0-9]*\)> .*$/\1/p' "$FAKE_PRE_CAS_WRITER_LOG")"
  wrapper_destination="$(sed -n 's/^ln wrapper .* destination=<\(.*\)>$/\1/p' "$FAKE_PRE_CAS_WRITER_LOG")"
  if [[ -z "$writer_pid" || -z "$writer_ppid" || -z "$wrapper_pid" || \
        -z "$waited_pid" || -z "$writer_destination" || -z "$wrapper_destination" ]]; then
    fail 'pre-CAS writer PID or destination evidence is missing or malformed'
  fi
  if [[ "$writer_pid" != "$waited_pid" || "$writer_ppid" != "$wrapper_pid" || \
        "$writer_pid" == "$wrapper_pid" || "$wrapper_pid" == "$$" ]]; then
    fail 'pre-CAS writer did not run as the distinct child waited by the ln wrapper'
  fi
  if [[ "$writer_destination" != "$wrapper_destination" ]]; then
    fail 'pre-CAS writer and ln wrapper did not record the same restore destination'
  fi
  case "$wrapper_destination" in
    "$FAKE_RESTORE_TEMP_PREFIX"*/current) ;;
    *) fail "pre-CAS writer destination is outside the restore temp directory: $wrapper_destination" ;;
  esac
}

assert_sdk_self_signal_ran() {
  local sdk_pid
  local signal_pid

  assert_file_contains "$FAKE_SDK_SIGNAL_LOG" 'signal=<TERM>' \
    'fake SDK records the TERM injection'
  sdk_pid="$(sed -n 's/^sdk pid=<\([0-9][0-9]*\)>$/\1/p' "$FAKE_SDK_LOG" | sed -n '1p')"
  signal_pid="$(sed -n 's/^sdk-signal pid=<\([0-9][0-9]*\)> signal=<TERM>$/\1/p' "$FAKE_SDK_SIGNAL_LOG")"
  if [[ -z "$sdk_pid" || -z "$signal_pid" || "$sdk_pid" != "$signal_pid" ]]; then
    fail 'TERM was not sent by the SDK function running in the runner process'
  fi
}

assert_lock_initialization_signal_ran() {
  local signal_pid
  local runner_pid

  assert_file_contains "$FAKE_MKDIR_SIGNAL_LOG" 'lock-init-signal pid=<' \
    'fake mkdir records the lock-initialization TERM injection'
  signal_pid="$(sed -n 's/^lock-init-signal pid=<\([0-9][0-9]*\)> parent=<.*$/\1/p' "$FAKE_MKDIR_SIGNAL_LOG")"
  runner_pid="$(sed -n 's/^lock-init-signal pid=<[0-9][0-9]*> parent=<\([0-9][0-9]*\)> .*$/\1/p' "$FAKE_MKDIR_SIGNAL_LOG")"
  if [[ -z "$signal_pid" || -z "$runner_pid" || "$signal_pid" == "$runner_pid" ]]; then
    fail 'lock-initialization TERM injection did not identify distinct wrapper and runner PIDs'
  fi
}

assert_no_env_snapshot_dirs() {
  local leftover

  for leftover in "$case_tmp_dir"/sdkman-switch-jdk-env.*; do
    if [[ -e "$leftover" ]]; then
      fail "SDKMAN environment snapshot directory remains: $leftover"
    fi
  done
}

assert_gnu_fallback_writer_ran() {
  local expected_target="$1"
  local wrapper_pid
  local writer_pid

  assert_file_contains "$FAKE_MV_GNU_FALLBACK_WRITER_MARKER" \
    'gnu-fallback-writer-ready pid=<' \
    'GNU fallback writer records its readiness marker and PID'
  assert_file_contains "$FAKE_MV_GNU_FALLBACK_WRITER_LOG" \
    "target=<$expected_target>" \
    'GNU fallback writer records the competing target'
  assert_file_contains "$FAKE_MV_LOG" 'mv gnu-fallback parent-pid=<' \
    'fake mv waits for the GNU fallback writer'
  wrapper_pid="$(sed -n 's/^mv gnu-fallback parent-pid=<\([0-9][0-9]*\)> waited-writer-pid=<.*> target=<.*>$/\1/p' "$FAKE_MV_LOG")"
  writer_pid="$(sed -n 's/^gnu-fallback-writer-complete pid=<\([0-9][0-9]*\)> candidate=<.*> target=<.*>$/\1/p' "$FAKE_MV_GNU_FALLBACK_WRITER_LOG")"
  if [[ -z "$wrapper_pid" || -z "$writer_pid" ]]; then
    fail 'GNU fallback writer PID evidence is missing or malformed'
  fi
  if [[ "$wrapper_pid" == "$writer_pid" ]]; then
    fail 'GNU fallback writer did not run in a distinct subprocess'
  fi
}

scenario_install_success_absolute_unchanged() {
  begin_case install_success_absolute_unchanged
  local old_identifier='17.0.9-tem'
  local target_identifier='21.0.9-tem'
  create_java_candidate "$case_java_dir/$old_identifier"
  set_default absolute "$old_identifier"
  export FAKE_SDK_INSTALL_MUTATE=none
  export FAKE_MV_MODE=bsd

  run_capture bash "$install_script" "$target_identifier"
  assert_status 0 'install success returns zero'
  assert_default_state "link:$case_java_dir/$old_identifier" 'absolute default is restored'
  assert_file_executable "$case_java_dir/$target_identifier/bin/java" 'successful install creates executable java'
  assert_file_contains "$FAKE_INIT_LOG" 'SDKMAN_ENV=<<unset>>' 'install clears SDKMAN_ENV before init'
  assert_file_contains "$FAKE_INIT_LOG" "SDKMAN_OLD_PWD=<$case_pwd>" 'install pins SDKMAN_OLD_PWD to the invoking directory'
  assert_file_contains "$FAKE_SDK_LOG" 'sdk USE=<n>' 'install pre-seeds the default answer with USE=n'
  assert_file_contains "$FAKE_SDK_LOG" 'sdk arg[0]=<install>' 'install calls sdk install'
  assert_file_contains "$FAKE_SDK_LOG" "sdk arg[2]=<$target_identifier>" 'install passes exact identifier'
  assert_file_contains "$FAKE_SDK_LOG" 'sdk stdin=<n>' 'install answers the default prompt with n'
  assert_file_empty "$FAKE_MV_LOG" 'unchanged absolute default does not call mv'
  assert_file_contains "$case_dir/stdout" "Java $target_identifier is installed" 'install reports success'
  assert_no_restore_temp_dirs
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_install_success_relative_unchanged() {
  begin_case install_success_relative_unchanged
  local old_identifier='17.0.9-tem'
  local target_identifier='21.0.9-tem'
  create_java_candidate "$case_java_dir/$old_identifier"
  set_default relative "$old_identifier" "../java/$old_identifier"
  export FAKE_SDK_INSTALL_MUTATE=none
  export FAKE_MV_MODE=gnu

  run_capture bash "$install_script" "$target_identifier"
  assert_status 0 'install success with relative default returns zero'
  assert_default_state "link:../java/$old_identifier" 'relative default is restored exactly'
  assert_file_executable "$case_java_dir/$target_identifier/bin/java" 'relative-default install creates executable java'
  assert_file_empty "$FAKE_MV_LOG" 'unchanged relative default does not call mv'
  assert_no_restore_temp_dirs
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_install_success_absent() {
  begin_case install_success_absent
  local target_identifier='21.0.9-tem'
  set_default absent "$target_identifier"
  export FAKE_SDK_INSTALL_MUTATE=none

  run_capture bash "$install_script" "$target_identifier"
  assert_status 0 'install success with absent default returns zero'
  assert_default_state absent 'absent default remains absent'
  assert_file_executable "$case_java_dir/$target_identifier/bin/java" 'absent-default install creates executable java'
  assert_file_empty "$FAKE_MV_LOG" 'absent-default restoration does not call mv'
  assert_file_contains "$case_dir/stdout" 'default is unchanged' 'absent-default install reports unchanged default'
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_install_failure_preserves_status() {
  begin_case install_failure_preserves_status
  local old_identifier='17.0.9-tem'
  local target_identifier='21.0.9-tem'
  create_java_candidate "$case_java_dir/$old_identifier"
  set_default relative "$old_identifier" "../java/$old_identifier"
  export FAKE_SDK_INSTALL_STATUS=17
  export FAKE_SDK_INSTALL_MUTATE=target_rel

  run_capture bash "$install_script" "$target_identifier"
  assert_status 17 'install failure preserves sdk status'
  assert_default_state "link:../java/$old_identifier" 'install failure restores original relative default'
  assert_file_contains "$case_dir/stderr" 'status 17' 'install failure reports sdk status'
  assert_file_contains "$FAKE_MV_LOG" 'mv arg[0]=<-fh>' 'install failure restores through mv'
  assert_no_restore_temp_dirs
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_install_failure_option_like_default() {
  begin_case install_failure_option_like_default
  local target_identifier='21.0.9-tem'
  local raw_target='-f'
  set_default relative unused "$raw_target"
  export FAKE_SDK_INSTALL_STATUS=17
  export FAKE_SDK_INSTALL_MUTATE=target_rel

  run_capture bash "$install_script" "$target_identifier"
  assert_status 17 'install failure preserves status with option-like default target'
  assert_link_target_raw "$raw_target" "$case_current" 'option-like default target is restored byte-for-byte'
  assert_path_absent "$case_dir/current" 'rollback does not create a CWD current symlink'
  assert_no_restore_temp_dirs
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_install_failure_trailing_newline_default() {
  begin_case install_failure_trailing_newline_default
  local target_identifier='21.0.9-tem'
  local raw_target=$'../java/legacy-java\n'
  set_default relative unused "$raw_target"
  export FAKE_SDK_INSTALL_STATUS=17
  export FAKE_SDK_INSTALL_MUTATE=target_rel

  run_capture bash "$install_script" "$target_identifier"
  assert_status 17 'install failure preserves status with newline-terminated default target'
  assert_link_target_raw "$raw_target" "$case_current" 'trailing-newline default target is restored byte-for-byte'
  assert_no_restore_temp_dirs
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_install_unexpected_default_from_absent() {
  begin_case install_unexpected_default_from_absent
  local target_identifier='21.0.9-tem'
  set_default absent unused
  export FAKE_SDK_INSTALL_MUTATE=target_rel

  run_capture bash "$install_script" "$target_identifier"
  assert_status 1 'unexpected default created from absent is rejected after restore'
  assert_default_state absent 'unexpected default created from absent is removed'
  assert_file_empty "$FAKE_MV_LOG" 'absent restoration uses unlink instead of mv'
  assert_file_contains "$case_dir/stderr" 'previous state was restored' 'absent restoration is reported'
  assert_no_restore_temp_dirs
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_install_unexpected_default_gnu_fallback() {
  begin_case install_unexpected_default_gnu_fallback
  local old_identifier='17.0.9-tem'
  local target_identifier='21.0.9-tem'
  create_java_candidate "$case_java_dir/$old_identifier"
  set_default relative "$old_identifier" "../java/$old_identifier"
  export FAKE_SDK_INSTALL_MUTATE=target_rel
  export FAKE_MV_MODE=gnu

  run_capture bash "$install_script" "$target_identifier"
  assert_status 1 'unexpected install default change is rejected after restore'
  assert_default_state "link:../java/$old_identifier" 'GNU fallback restores the original relative default'
  assert_file_contains "$FAKE_MV_LOG" 'mv arg[0]=<-fh>' 'GNU restore first probes BSD mv'
  assert_file_contains "$FAKE_MV_LOG" 'mv arg[0]=<-Tf>' 'GNU restore uses -Tf fallback'
  assert_file_contains "$case_dir/stderr" 'previous state was restored' 'unexpected install default change is reported'
  assert_no_restore_temp_dirs
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_install_restore_failure() {
  begin_case install_restore_failure
  local old_identifier='17.0.9-tem'
  local target_identifier='21.0.9-tem'
  create_java_candidate "$case_java_dir/$old_identifier"
  set_default absolute "$old_identifier"
  export FAKE_SDK_INSTALL_MUTATE=target_rel
  export FAKE_MV_MODE=fail

  run_capture bash "$install_script" "$target_identifier"
  assert_status 1 'install restoration failure returns one'
  assert_default_state "link:$target_identifier" 'failed install restoration leaves observed changed default'
  assert_file_contains "$FAKE_MV_LOG" 'mv arg[0]=<-fh>' 'restore failure records BSD mv attempt'
  assert_file_contains "$FAKE_MV_LOG" 'mv arg[0]=<-Tf>' 'restore failure records GNU fallback attempt'
  assert_file_contains "$case_dir/stderr" 'automatic restoration failed' 'restore failure is reported'
  assert_no_restore_temp_dirs
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_install_incomplete_candidate() {
  begin_case install_incomplete_candidate
  local old_identifier='17.0.9-tem'
  local target_identifier='21.0.9-tem'
  create_java_candidate "$case_java_dir/$old_identifier"
  create_incomplete_candidate "$case_java_dir/$target_identifier"
  set_default absolute "$old_identifier"

  run_capture bash "$install_script" "$target_identifier"
  assert_status 1 'incomplete install candidate is rejected'
  assert_default_state "link:$case_java_dir/$old_identifier" 'incomplete candidate does not alter default'
  assert_file_empty "$FAKE_SDK_LOG" 'incomplete candidate skips sdk install'
  assert_file_contains "$case_dir/stderr" 'incomplete SDKMAN Java candidate' 'incomplete candidate is reported'
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_install_reserved_current() {
  begin_case install_reserved_current

  run_capture bash "$install_script" current
  assert_status 2 'reserved current identifier is rejected'
  assert_file_empty "$FAKE_INIT_LOG" 'reserved install identifier is rejected before SDKMAN init'
  assert_file_contains "$case_dir/stderr" 'reserved name' 'reserved install identifier is reported'
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_install_concurrent_third_writer() {
  begin_case install_concurrent_third_writer
  local old_identifier='17.0.9-tem'
  local target_identifier='21.0.9-tem'
  local third_identifier='22.0.1-tem'
  local third_target="$case_java_dir/$third_identifier"
  create_java_candidate "$case_java_dir/$old_identifier"
  create_java_candidate "$third_target"
  set_default absolute "$old_identifier"
  export FAKE_SDK_INSTALL_MUTATE=target_rel
  export FAKE_SDK_THIRD_WRITER_TARGET="$third_target"

  run_capture bash "$install_script" "$target_identifier"
  assert_status 1 'install refuses a concurrent third-writer default change'
  assert_third_writer_ran "$third_target"
  assert_default_state "link:$third_target" \
    'install preserves the third writer default instead of restoring the stale original default'
  assert_file_contains "$case_dir/stderr" 'drifted after the SDKMAN operation' \
    'install reports the concurrent drift refusal'
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_install_term_reconciles_default() {
  begin_case install_term_reconciles_default
  local old_identifier='17.0.9-tem'
  local target_identifier='21.0.9-tem'

  create_java_candidate "$case_java_dir/$old_identifier"
  set_default absolute "$old_identifier"
  export FAKE_SDK_INSTALL_MUTATE=target_rel
  export FAKE_SDK_SIGNAL_AFTER_MUTATION=TERM

  run_capture bash "$install_script" "$target_identifier"
  assert_status 143 'install preserves TERM status after safe cleanup'
  assert_sdk_self_signal_ran
  assert_default_state "link:$case_java_dir/$old_identifier" \
    'install TERM cleanup restores the original Java default'
  assert_path_absent "$SDKMAN_CANDIDATES_DIR/.sdkman-switch-jdk.lock" \
    'install TERM cleanup releases the owned lock'
  assert_no_restore_temp_dirs
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_lock_live_owner_refusal() {
  begin_case lock_live_owner_refusal
  local old_identifier='17.0.9-tem'
  local target_identifier='21.0.9-tem'
  local lock_dir

  create_java_candidate "$case_java_dir/$old_identifier"
  set_default absolute "$old_identifier"
  start_live_lock_owner
  write_complete_lock_fixture "$live_lock_owner_pid" 'live-owner-fixture'
  lock_dir="$live_lock_fixture_dir"
  snapshot_lock_fixture "$lock_dir"

  run_capture bash "$install_script" "$target_identifier"
  assert_default_state "link:$case_java_dir/$old_identifier" 'live lock refusal leaves the default unchanged'
  assert_lock_fixture_unchanged "$lock_dir"
  release_live_lock_fixture
  assert_file_empty "$FAKE_SDK_LOG" 'live lock blocks SDKMAN invocation'
  assert_status 1 'live lock owner refusal returns one'
  assert_no_restore_temp_dirs
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_lock_stale_owner_recovery() {
  begin_case lock_stale_owner_recovery
  local target_identifier='21.0.9-tem'
  local stale_owner_pid
  local lock_dir

  "$BASH" -c 'exit 0' &
  stale_owner_pid=$!
  wait "$stale_owner_pid"
  if kill -0 "$stale_owner_pid" 2>/dev/null; then
    fail "stale lock owner PID is unexpectedly live: $stale_owner_pid"
  fi
  write_complete_lock_fixture "$stale_owner_pid" 'stale-owner-fixture'
  lock_dir="$live_lock_fixture_dir"

  run_capture bash "$install_script" "$target_identifier"
  assert_status 0 'stale lock is reaped before a successful install'
  assert_file_contains "$FAKE_SDK_LOG" 'sdk arg[0]=<install>' 'stale lock recovery proceeds with SDKMAN'
  assert_path_absent "$lock_dir" 'stale lock is absent after the operation'
  live_lock_fixture_dir=''
  assert_no_restore_temp_dirs
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_lock_initialization_term_cleans_partial_lock() {
  begin_case lock_initialization_term_cleans_partial_lock
  local existing_identifier='21.0.9-tem'

  create_java_candidate "$case_java_dir/$existing_identifier"
  set_default absolute "$existing_identifier"
  export FAKE_MKDIR_SIGNAL_LOCK_INIT=TERM

  run_capture bash "$install_script" "$existing_identifier"
  assert_status 143 'TERM during lock initialization preserves the signal status'
  assert_lock_initialization_signal_ran
  assert_default_state "link:$case_java_dir/$existing_identifier" \
    'TERM before SDKMAN invocation leaves the Java default unchanged'
  assert_path_absent "$SDKMAN_CANDIDATES_DIR/.sdkman-switch-jdk.lock" \
    'TERM during lock initialization removes the partial owned lock'
  assert_file_empty "$FAKE_SDK_LOG" \
    'TERM during lock initialization exits before SDKMAN invocation'
  assert_no_restore_temp_dirs
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_restore_pre_cas_third_writer() {
  begin_case restore_pre_cas_third_writer
  local old_identifier='17.0.9-tem'
  local target_identifier='21.0.9-tem'
  local third_identifier='22.0.1-tem'
  local third_target="$case_java_dir/$third_identifier"

  create_java_candidate "$case_java_dir/$old_identifier"
  create_java_candidate "$third_target"
  set_default absolute "$old_identifier"
  export FAKE_SDK_INSTALL_MUTATE=target_rel
  export FAKE_LN_PRE_CAS_WRITER_TARGET="$third_target"

  run_capture bash "$install_script" "$target_identifier"
  assert_status 1 'rollback pre-CAS third-writer refusal returns one'
  assert_pre_cas_writer_ran "$third_target"
  assert_default_state "link:$third_target" 'rollback preserves the pre-CAS third-writer target instead of overwriting it with A'
  assert_file_contains "$case_dir/stderr" 'rollback drift' 'rollback reports its pre-CAS drift refusal'
  assert_file_empty "$FAKE_MV_LOG" 'rollback drift refusal does not call mv'
  assert_no_restore_temp_dirs
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_restore_gnu_fallback_third_writer() {
  begin_case restore_gnu_fallback_third_writer
  local old_identifier='17.0.9-tem'
  local target_identifier='21.0.9-tem'
  local third_identifier='22.0.1-tem'
  local third_target="$case_java_dir/$third_identifier"

  create_java_candidate "$case_java_dir/$old_identifier"
  create_java_candidate "$third_target"
  set_default absolute "$old_identifier"
  export FAKE_SDK_INSTALL_MUTATE=target_rel
  export FAKE_MV_MODE=gnu
  export FAKE_MV_GNU_FALLBACK_WRITER_TARGET="$third_target"

  run_capture bash "$install_script" "$target_identifier"
  assert_status 1 'GNU fallback third-writer refusal returns one'
  assert_gnu_fallback_writer_ran "$third_target"
  assert_default_state "link:$third_target" \
    'GNU fallback second read preserves the competing default instead of overwriting it with A'
  assert_file_contains "$case_dir/stderr" 'rollback drift' \
    'GNU fallback race reports rollback drift'
  assert_file_not_contains "$FAKE_MV_LOG" 'mv arg[0]=<-Tf>' \
    'GNU fallback race refusal never attempts the GNU mv replacement'
  assert_no_restore_temp_dirs
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_run_existing_candidate_without_init() {
  begin_case run_existing_candidate_without_init
  local target_identifier='21.0.9-tem'
  local stateless_root="$case_dir/sdkman stateless root"
  local stateless_candidates
  local target
  local malformed_current
  local attacker_candidates="$case_dir/attacker candidates;literal"

  mkdir -p "$stateless_root/bin" "$attacker_candidates/java"
  stateless_root="$(cd "$stateless_root" && pwd -P)"
  stateless_candidates="$stateless_root/candidates"
  target="$stateless_candidates/java/$target_identifier"
  malformed_current="$stateless_candidates/java/current"
  create_java_candidate "$target"
  create_incomplete_candidate "$attacker_candidates/java/$target_identifier"
  printf '%s\n' 'not-a-symlink' > "$malformed_current"
  cp "$malformed_current" "$case_dir/current-before"
  export SDKMAN_DIR="$stateless_root"
  export SDKMAN_CANDIDATES_DIR="$attacker_candidates"
  export FAKE_PAYLOAD_STATUS=23

  run_capture bash "$run_script" "$target_identifier" -- "$case_dir/payload" \
    'arg with spaces' '' 'glob*value?' '--flag=value'
  assert_status 23 'installed candidate runs without SDKMAN init'
  assert_file_empty "$FAKE_INIT_LOG" 'stateless runner does not source SDKMAN init'
  assert_file_empty "$FAKE_SDK_LOG" 'stateless runner does not invoke sdk'
  assert_file_not_contains "$FAKE_MKDIR_LOG" \
    "mkdir destination=<$stateless_candidates/.sdkman-switch-jdk.lock>" \
    'stateless runner does not attempt a lock mkdir'
  assert_path_absent "$stateless_candidates/.sdkman-switch-jdk.lock" \
    'stateless runner does not create a lock beside its candidate'
  assert_path_absent "$attacker_candidates/.sdkman-switch-jdk.lock" \
    'stateless runner ignores injected SDKMAN_CANDIDATES_DIR'
  if ! cmp "$case_dir/current-before" "$malformed_current" >/dev/null 2>&1; then
    fail 'stateless runner changed a malformed current path'
  fi
  {
    printf 'payload JAVA_HOME=<%s>\n' "$target"
    printf 'payload PATH=<%s>\n' "$target/bin:$fake_bin:$original_path"
    printf 'payload java=<%s>\n' "$target/bin/java"
    printf 'payload argc=4\n'
    printf 'payload arg[0]=<arg with spaces>\n'
    printf 'payload arg[1]=<>\n'
    printf 'payload arg[2]=<glob*value?>\n'
    printf 'payload arg[3]=<--flag=value>\n'
  } > "$case_dir/expected-payload.log"
  if ! cmp "$case_dir/expected-payload.log" "$FAKE_PAYLOAD_LOG" >/dev/null 2>&1; then
    fail 'stateless runner did not preserve payload argv or environment exactly'
  fi
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_run_empty_path_is_safe() {
  begin_case run_empty_path_is_safe
  local target_identifier='21.0.9-tem'
  local stateless_root="$case_dir/sdkman-empty-path"
  local target

  mkdir -p "$stateless_root/bin"
  stateless_root="$(cd "$stateless_root" && pwd -P)"
  target="$stateless_root/candidates/java/$target_identifier"
  create_java_candidate "$target" /bin/bash
  export SDKMAN_DIR="$stateless_root"
  unset SDKMAN_CANDIDATES_DIR
  export FAKE_PAYLOAD_STATUS=29
  export PATH=''
  run_capture /bin/bash "$run_script" "$target_identifier" -- /bin/bash "$case_dir/payload" empty-path
  export PATH="$fake_bin:$original_path"

  assert_status 29 'empty caller PATH preserves the payload status'
  assert_file_empty "$FAKE_INIT_LOG" 'empty PATH fast path does not source SDKMAN init'
  assert_file_empty "$FAKE_SDK_LOG" 'empty PATH fast path does not invoke sdk'
  assert_file_not_contains "$FAKE_MKDIR_LOG" \
    "mkdir destination=<$stateless_root/candidates/.sdkman-switch-jdk.lock>" \
    'empty PATH fast path does not attempt a lock mkdir'
  assert_file_contains "$FAKE_JAVA_LOG" 'java arg[0]=<-version>' \
    'absolute-shebang candidate java performs the version probe'
  {
    printf 'payload JAVA_HOME=<%s>\n' "$target"
    printf 'payload PATH=<%s>\n' "$target/bin"
    printf 'payload java=<%s>\n' "$target/bin/java"
    printf 'payload argc=1\n'
    printf 'payload arg[0]=<empty-path>\n'
  } > "$case_dir/expected-payload.log"
  if ! cmp "$case_dir/expected-payload.log" "$FAKE_PAYLOAD_LOG" >/dev/null 2>&1; then
    fail 'empty PATH runner did not preserve the exact isolated payload environment'
  fi
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_run_compound_bash_c_keeps_runner_jdk() {
  begin_case run_compound_bash_c_keeps_runner_jdk
  local target_identifier='21.0.9-tem'
  local stateless_root="$case_dir/sdkman-compound"
  local target
  local profile_java="$case_dir/profile-java"

  mkdir -p "$stateless_root"
  stateless_root="$(cd "$stateless_root" && pwd -P)"
  target="$stateless_root/candidates/java/$target_identifier"
  create_java_candidate "$target"
  create_java_candidate "$profile_java"
  export SDKMAN_DIR="$stateless_root"
  unset SDKMAN_CANDIDATES_DIR
  {
    printf 'export JAVA_HOME=%q\n' "$profile_java"
    printf 'export PATH=%q/bin:$PATH\n' "$profile_java"
  } > "$HOME/.bash_profile"
  export FAKE_PAYLOAD_STATUS=31

  run_capture bash "$run_script" "$target_identifier" -- \
    bash -lc 'exec "$@"' bash "$case_dir/payload" login-control
  assert_status 31 'login-shell control preserves the payload status'
  assert_file_contains "$FAKE_PAYLOAD_LOG" "payload JAVA_HOME=<$profile_java>" \
    'bash -lc control proves the profile can overwrite JAVA_HOME'
  assert_file_contains "$FAKE_PAYLOAD_LOG" "payload java=<$profile_java/bin/java>" \
    'bash -lc control proves the profile can overwrite PATH'

  : > "$FAKE_PAYLOAD_LOG"
  run_capture bash "$run_script" "$target_identifier" -- \
    bash -c 'exec "$@"' bash "$case_dir/payload" non-login
  assert_status 31 'non-login compound command preserves the payload status'
  assert_file_contains "$FAKE_PAYLOAD_LOG" "payload JAVA_HOME=<$target>" \
    'bash -c keeps the runner JAVA_HOME'
  assert_file_contains "$FAKE_PAYLOAD_LOG" "payload java=<$target/bin/java>" \
    'bash -c keeps the runner java path'
  assert_file_contains "$FAKE_PAYLOAD_LOG" 'payload arg[0]=<non-login>' \
    'bash -c preserves compound-command argv'
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_lock_create_failure_is_not_type_error() {
  begin_case lock_create_failure_is_not_type_error
  local target_identifier='21.0.9-tem'
  local lock_path="$SDKMAN_CANDIDATES_DIR/.sdkman-switch-jdk.lock"

  export FAKE_MKDIR_FAIL_PATH="$lock_path"
  export FAKE_MKDIR_FAIL_STATUS=13
  run_capture bash "$install_script" "$target_identifier"
  assert_status 1 'lock creation failure returns one'
  assert_path_absent "$lock_path" 'failed lock creation leaves no lock path'
  assert_file_contains "$FAKE_MKDIR_LOG" "mkdir destination=<$lock_path>" \
    'fake mkdir received the lock creation request'
  assert_file_empty "$FAKE_SDK_LOG" 'lock creation failure blocks sdk invocation'
  assert_file_not_contains "$case_dir/stderr" 'not a directory' \
    'absent lock path is not misreported as a type error'
  assert_file_contains "$case_dir/stderr" 'Could not create the SDKMAN default-state lock' \
    'lock creation failure is reported as a creation failure'
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_lock_regular_file_is_unsafe() {
  begin_case lock_regular_file_is_unsafe
  local target_identifier='21.0.9-tem'
  local lock_path="$SDKMAN_CANDIDATES_DIR/.sdkman-switch-jdk.lock"

  printf '%s\n' 'untrusted regular file' > "$lock_path"
  cp "$lock_path" "$case_dir/lock-before"
  run_capture bash "$install_script" "$target_identifier"
  assert_status 1 'regular-file lock path returns one'
  if ! cmp "$case_dir/lock-before" "$lock_path" >/dev/null 2>&1; then
    fail 'regular-file lock path was modified'
  fi
  assert_file_empty "$FAKE_SDK_LOG" 'regular-file lock path blocks sdk invocation'
  assert_file_contains "$case_dir/stderr" 'SDKMAN default-state lock path is unsafe' \
    'regular-file lock path is reported as unsafe'
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_lock_symlink_is_unsafe() {
  begin_case lock_symlink_is_unsafe
  local target_identifier='21.0.9-tem'
  local lock_path="$SDKMAN_CANDIDATES_DIR/.sdkman-switch-jdk.lock"
  local raw_target='../untrusted-lock-target'

  ln -s -- "$raw_target" "$lock_path"
  run_capture bash "$install_script" "$target_identifier"
  assert_status 1 'symlink lock path returns one'
  assert_link_target_raw "$raw_target" "$lock_path" 'symlink lock path was not modified'
  assert_file_empty "$FAKE_SDK_LOG" 'symlink lock path blocks sdk invocation'
  assert_file_contains "$case_dir/stderr" 'SDKMAN default-state lock path is unsafe' \
    'symlink lock path is reported as unsafe'
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_run_incomplete_candidate() {
  begin_case run_incomplete_candidate
  local target_identifier='21.0.9-tem'
  local stateless_root="$case_dir/sdkman-incomplete"

  create_incomplete_candidate "$stateless_root/candidates/java/$target_identifier"
  export SDKMAN_DIR="$stateless_root"
  unset SDKMAN_CANDIDATES_DIR

  run_capture bash "$run_script" "$target_identifier" -- "$case_dir/payload" should-not-run
  assert_status 1 'incomplete run candidate is rejected'
  assert_file_empty "$FAKE_SDK_LOG" 'incomplete run candidate skips sdk use'
  assert_file_empty "$FAKE_PAYLOAD_LOG" 'payload does not run for incomplete candidate'
  assert_file_contains "$case_dir/stderr" 'not installed or is incomplete' 'incomplete run candidate is reported'
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_run_relative_sdkman_dir_is_rejected() {
  begin_case run_relative_sdkman_dir_is_rejected
  local target_identifier='21.0.9-tem'

  create_java_candidate "$case_dir/relative-sdkman/candidates/java/$target_identifier"
  export SDKMAN_DIR='relative-sdkman'
  unset SDKMAN_CANDIDATES_DIR

  run_capture /bin/bash "$run_script" "$target_identifier" -- "$case_dir/payload" should-not-run
  assert_status 1 'relative SDKMAN_DIR is rejected'
  assert_file_empty "$FAKE_JAVA_LOG" 'relative SDKMAN_DIR is rejected before probing Java'
  assert_file_empty "$FAKE_PAYLOAD_LOG" 'relative SDKMAN_DIR is rejected before the payload'
  assert_file_contains "$case_dir/stderr" 'SDKMAN_DIR must be an absolute path' \
    'relative SDKMAN_DIR reports the unsafe configuration'
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_run_invalid_identifiers_are_rejected() {
  begin_case run_invalid_identifiers_are_rejected
  local invalid_identifier

  export SDKMAN_DIR="$case_dir/sdkman-invalid-identifiers"
  unset SDKMAN_CANDIDATES_DIR
  for invalid_identifier in '../x' 'a/b' '/absolute' '.hidden' $'bad\nidentifier'; do
    : > "$FAKE_JAVA_LOG"
    : > "$FAKE_PAYLOAD_LOG"
    run_capture /bin/bash "$run_script" "$invalid_identifier" -- "$case_dir/payload" should-not-run
    assert_status 2 "invalid identifier is rejected: $invalid_identifier"
    assert_file_empty "$FAKE_JAVA_LOG" 'invalid identifier is rejected before probing Java'
    assert_file_empty "$FAKE_PAYLOAD_LOG" 'invalid identifier is rejected before the payload'
    assert_file_contains "$case_dir/stderr" 'Invalid SDKMAN Java identifier' \
      'invalid identifier reports the validation failure'
  done
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_run_java_probe_failure_blocks_payload() {
  begin_case run_java_probe_failure_blocks_payload
  local target_identifier='21.0.9-tem'
  local stateless_root="$case_dir/sdkman-probe-failure"
  local target="$stateless_root/candidates/java/$target_identifier"

  create_java_candidate "$target" /bin/bash
  export SDKMAN_DIR="$stateless_root"
  unset SDKMAN_CANDIDATES_DIR
  export FAKE_JAVA_STATUS=17

  run_capture /bin/bash "$run_script" "$target_identifier" -- /bin/bash "$case_dir/payload" should-not-run
  assert_status 17 'java version probe failure status is preserved'
  assert_file_contains "$FAKE_JAVA_LOG" 'java arg[0]=<-version>' \
    'failed candidate java performs the version probe'
  assert_file_empty "$FAKE_PAYLOAD_LOG" 'failed Java probe blocks the payload'
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_run_reserved_current() {
  begin_case run_reserved_current

  run_capture bash "$run_script" current -- "$case_dir/payload"
  assert_status 2 'reserved current run identifier is rejected'
  assert_file_empty "$FAKE_INIT_LOG" 'reserved run identifier is rejected before SDKMAN init'
  assert_file_empty "$FAKE_PAYLOAD_LOG" 'payload does not run for reserved identifier'
  assert_file_contains "$case_dir/stderr" 'reserved name' 'reserved run identifier is reported'
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_full_env_atomic_sdkmanrc_replace_is_rejected_and_reconciled() {
  begin_case full_env_atomic_sdkmanrc_replace_is_rejected_and_reconciled
  local old_java_identifier='17.0.9-tem'
  local java_identifier='21.0.9-tem'
  local old_maven_identifier='3.8.6'
  local maven_identifier='3.9.8'

  create_java_candidate "$case_java_dir/$java_identifier"
  set_candidate_default java relative "$old_java_identifier" "../java/$old_java_identifier"
  set_candidate_default maven relative "$old_maven_identifier" "../maven/$old_maven_identifier"
  write_sdkmanrc "java=$java_identifier"
  printf 'java=%s\nmaven=%s\n' "$java_identifier" "$maven_identifier" > \
    "$case_dir/.sdkmanrc.replacement"
  export FAKE_SDK_ENV_REPLACEMENT="$case_dir/.sdkmanrc.replacement"
  export FAKE_PROJECT_SDKMANRC="$case_dir/.sdkmanrc"

  run_capture bash "$full_env_script" -- "$case_dir/payload" should-not-run
  assert_file_contains "$FAKE_SDK_ENV_REPLACE_LOG" 'sdkmanrc-replace pid=<' \
    'fake SDK atomically replaces the project .sdkmanrc after runner parsing'
  assert_path_absent "$case_dir/.sdkmanrc.replacement" \
    'the replacement file was atomically renamed onto the project .sdkmanrc'
  assert_file_contains "$case_dir/.sdkmanrc" "maven=$maven_identifier" \
    'the concurrent project .sdkmanrc replacement remains untouched'
  assert_file_contains "$FAKE_SDK_LOG" 'sdk arg[0]=<install>' \
    'runner explicitly installs the validated Java entry'
  assert_file_not_contains "$FAKE_SDK_LOG" 'sdk arg[1]=<maven>' \
    'the atomically replaced .sdkmanrc cannot add an SDKMAN operation'
  assert_file_not_contains "$FAKE_SDK_LOG" 'sdk arg[0]=<env>' \
    'runner never delegates a second .sdkmanrc read to sdk env'
  assert_status 1 'project .sdkmanrc drift blocks payload execution'
  assert_candidate_default_state java "link:../java/$old_java_identifier" \
    'Java is reconciled after project .sdkmanrc drift'
  assert_candidate_default_state maven "link:../maven/$old_maven_identifier" \
    'an unparsed replacement candidate cannot change the Maven default'
  assert_file_empty "$FAKE_PAYLOAD_LOG" \
    'project .sdkmanrc drift blocks the payload'
  assert_file_contains "$case_dir/stderr" 'changed while the SDKMAN environment was being activated' \
    'project .sdkmanrc drift is reported'
  assert_path_absent "$SDKMAN_CANDIDATES_DIR/.sdkman-switch-jdk.lock" \
    'project .sdkmanrc drift cleanup releases the owned lock'
  assert_no_env_snapshot_dirs
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_full_env_term_reconciles_operation_owned_defaults() {
  begin_case full_env_term_reconciles_operation_owned_defaults
  local old_java_identifier='17.0.9-tem'
  local java_identifier='21.0.9-tem'
  local old_maven_identifier='3.8.6'
  local maven_identifier='3.9.8'

  create_java_candidate "$case_java_dir/$java_identifier"
  set_candidate_default java relative "$old_java_identifier" "../java/$old_java_identifier"
  set_candidate_default maven relative "$old_maven_identifier" "../maven/$old_maven_identifier"
  write_sdkmanrc "java=$java_identifier" "maven=$maven_identifier"
  export FAKE_SDK_SIGNAL_AFTER_MUTATION=TERM
  export FAKE_SDK_SIGNAL_AFTER_CANDIDATE=maven
  export FAKE_SDK_SIGNAL_AFTER_ACTION=use

  run_capture bash "$full_env_script" -- "$case_dir/payload" should-not-run
  assert_status 143 'full environment preserves TERM status after safe reconciliation'
  assert_sdk_self_signal_ran
  assert_candidate_default_state java "link:../java/$old_java_identifier" \
    'full-environment TERM cleanup restores the Java default'
  assert_candidate_default_state maven "link:../maven/$old_maven_identifier" \
    'full-environment TERM cleanup restores the Maven default'
  assert_file_empty "$FAKE_PAYLOAD_LOG" \
    'full-environment TERM cleanup blocks the payload'
  assert_path_absent "$SDKMAN_CANDIDATES_DIR/.sdkman-switch-jdk.lock" \
    'full-environment TERM cleanup releases the owned lock'
  assert_no_restore_temp_dirs
  assert_no_env_snapshot_dirs
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_full_env_success_allows_authorized_default() {
  begin_case full_env_success_allows_authorized_default
  local old_java_identifier='17.0.9-tem'
  local java_identifier='21.0.9-tem'
  local maven_identifier='3.9.8'
  local old_java_raw="../java/$old_java_identifier"

  create_java_candidate "$case_java_dir/$java_identifier"
  set_candidate_default java relative "$old_java_identifier" "$old_java_raw"
  set_candidate_default maven absent unused
  write_sdkmanrc "java=$java_identifier" "maven=$maven_identifier"
  set_full_env_operation_raw_target java "$java_identifier"
  set_full_env_operation_raw_target maven "$maven_identifier"
  export FAKE_PAYLOAD_STATUS=23

  run_capture bash "$full_env_script" --allow-default maven -- "$case_dir/payload" \
    'arg with spaces' '' 'glob*value?' '--flag=value'
  assert_status 23 'full environment preserves the payload status'
  assert_link_target_raw "$old_java_raw" "$case_current" \
    'unapproved Java default is restored byte-for-byte'
  assert_candidate_default_state maven "link:$maven_identifier" \
    'authorized absent Maven default remains the requested raw identifier'
  assert_file_contains "$FAKE_SDK_LOG" 'sdk arg[0]=<install>' \
    'full environment explicitly installs each validated entry'
  assert_file_contains "$FAKE_SDK_LOG" 'sdk arg[0]=<use>' \
    'full environment explicitly activates each validated entry'
  assert_file_contains "$FAKE_SDK_LOG" 'sdk arg[1]=<maven>' \
    'full environment applies the validated Maven entry directly'
  {
    printf 'payload JAVA_HOME=<%s>\n' "$case_java_dir/$java_identifier"
    printf 'payload PATH=<%s>\n' "$case_java_dir/$java_identifier/bin:$fake_bin:$original_path"
    printf 'payload java=<%s>\n' "$case_java_dir/$java_identifier/bin/java"
    printf 'payload argc=4\n'
    printf 'payload arg[0]=<arg with spaces>\n'
    printf 'payload arg[1]=<>\n'
    printf 'payload arg[2]=<glob*value?>\n'
    printf 'payload arg[3]=<--flag=value>\n'
  } > "$case_dir/expected-full-env-payload.log"
  if ! cmp "$case_dir/expected-full-env-payload.log" "$FAKE_PAYLOAD_LOG" >/dev/null 2>&1; then
    fail 'full environment did not preserve payload argv or SDKMAN environment'
  fi
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_full_env_restores_unapproved_defaults() {
  begin_case full_env_restores_unapproved_defaults
  local old_java_identifier='17.0.9-tem'
  local java_identifier='21.0.9-tem'
  local old_maven_raw=$'../maven/3.8.6\n'
  local maven_identifier='3.9.8'

  create_java_candidate "$case_java_dir/$java_identifier"
  set_candidate_default java relative "$old_java_identifier" "../java/$old_java_identifier"
  set_candidate_default maven relative unused "$old_maven_raw"
  write_sdkmanrc "java=$java_identifier" "maven=$maven_identifier"
  set_full_env_operation_raw_target java "$java_identifier"
  set_full_env_operation_raw_target maven "$maven_identifier"

  run_capture bash "$full_env_script" -- "$case_dir/payload" restored
  assert_status 0 'full environment with no authorization restores all changed defaults'
  assert_candidate_default_state java "link:../java/$old_java_identifier" \
    'unapproved Java default is restored'
  assert_link_target_raw "$old_maven_raw" "$(candidate_current_path maven)" \
    'unapproved Maven default is restored byte-for-byte'
  assert_file_contains "$FAKE_PAYLOAD_LOG" 'payload arg[0]=<restored>' \
    'payload runs after successful full-environment reconciliation'
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_full_env_cleanup_uses_pre_sdk_tools() {
  begin_case full_env_cleanup_uses_pre_sdk_tools
  local old_java_identifier='17.0.9-tem'
  local java_identifier='21.0.9-tem'

  create_java_candidate "$case_java_dir/$java_identifier"
  write_candidate_path_hijack "$case_java_dir/$java_identifier"
  set_candidate_default java relative "$old_java_identifier" "../java/$old_java_identifier"
  write_sdkmanrc "java=$java_identifier"

  run_capture bash "$full_env_script" -- "$case_dir/payload" safe-cleanup
  assert_status 0 'full environment succeeds when its activated candidate shadows mv'
  assert_candidate_default_state java "link:../java/$old_java_identifier" \
    'full environment restores the unapproved Java default with its captured tool'
  assert_file_empty "$FAKE_PATH_HIJACK_LOG" \
    'candidate PATH cannot replace the runner cleanup mv command'
  assert_file_contains "$FAKE_PAYLOAD_LOG" 'payload arg[0]=<safe-cleanup>' \
    'payload runs after cleanup uses the pre-SDK tool path'
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_full_env_concurrent_third_writer() {
  begin_case full_env_concurrent_third_writer
  local old_java_identifier='17.0.9-tem'
  local java_identifier='21.0.9-tem'
  local old_maven_identifier='3.8.6'
  local maven_identifier='3.9.8'
  local third_identifier='3.9.9'
  local third_target="$SDKMAN_CANDIDATES_DIR/maven/$third_identifier"

  create_java_candidate "$case_java_dir/$java_identifier"
  set_candidate_default java relative "$old_java_identifier" "../java/$old_java_identifier"
  set_candidate_default maven relative "$old_maven_identifier" "../maven/$old_maven_identifier"
  write_sdkmanrc "java=$java_identifier" "maven=$maven_identifier"
  export FAKE_SDK_THIRD_WRITER_CANDIDATE=maven
  export FAKE_SDK_THIRD_WRITER_TARGET="$third_target"
  export FAKE_SDK_THIRD_WRITER_AFTER_CANDIDATE=maven
  export FAKE_SDK_THIRD_WRITER_AFTER_ACTION=use

  run_capture bash "$full_env_script" -- "$case_dir/payload" should-not-run
  assert_status 1 'full environment refuses a concurrent third-writer default change'
  assert_third_writer_ran "$third_target" maven
  assert_candidate_default_state maven "link:$third_target" \
    'full environment preserves the third-writer Maven default'
  assert_candidate_default_state java "link:../java/$old_java_identifier" \
    'other candidates are reconciled after third-writer detection'
  assert_file_empty "$FAKE_PAYLOAD_LOG" \
    'payload does not run after a concurrent full-environment default change'
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_full_env_malformed_sdkmanrc() {
  begin_case full_env_malformed_sdkmanrc
  write_sdkmanrc 'java=21.0.9-tem' 'this line is malformed'

  run_capture bash "$full_env_script" -- "$case_dir/payload" should-not-run
  assert_status 2 'malformed .sdkmanrc is rejected as command-line misuse'
  assert_file_empty "$FAKE_SDK_LOG" 'malformed .sdkmanrc blocks sdk invocation'
  assert_file_empty "$FAKE_PAYLOAD_LOG" 'malformed .sdkmanrc blocks payload invocation'
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_full_env_unsupported_current() {
  begin_case full_env_unsupported_current
  local java_identifier='21.0.9-tem'
  local maven_identifier='3.9.8'

  create_java_candidate "$case_java_dir/$java_identifier"
  mkdir -p "$(candidate_current_path maven)"
  write_sdkmanrc "java=$java_identifier" "maven=$maven_identifier"

  run_capture bash "$full_env_script" -- "$case_dir/payload" should-not-run
  assert_status 1 'unsupported SDKMAN current path blocks full environment activation'
  assert_file_empty "$FAKE_SDK_LOG" 'unsupported current path blocks sdk invocation'
  assert_file_empty "$FAKE_PAYLOAD_LOG" 'unsupported current path blocks payload invocation'
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_full_env_restore_failure() {
  begin_case full_env_restore_failure
  local old_java_identifier='17.0.9-tem'
  local java_identifier='21.0.9-tem'
  local old_maven_raw='../maven/3.8.6'
  local maven_identifier='3.9.8'

  create_java_candidate "$case_java_dir/$java_identifier"
  set_candidate_default java relative "$old_java_identifier" "../java/$old_java_identifier"
  set_candidate_default maven relative unused "$old_maven_raw"
  write_sdkmanrc "java=$java_identifier" "maven=$maven_identifier"
  export FAKE_MV_FAIL_DESTINATION="$case_current"

  run_capture bash "$full_env_script" -- "$case_dir/payload" should-not-run
  assert_status 1 'full environment returns one when a default cannot be restored'
  assert_candidate_default_state java "link:$java_identifier" \
    'failed Java restoration leaves the observed post-SDKMAN default'
  assert_link_target_raw "$old_maven_raw" "$(candidate_current_path maven)" \
    'full environment continues best-effort reconciliation after Java restoration fails'
  assert_file_empty "$FAKE_PAYLOAD_LOG" 'payload does not run after restoration failure'
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_full_env_sdk_failure_blocks_payload() {
  begin_case full_env_sdk_failure_blocks_payload
  local old_java_identifier='17.0.9-tem'
  local java_identifier='21.0.9-tem'
  local old_maven_identifier='3.8.6'
  local maven_identifier='3.9.8'

  create_java_candidate "$case_java_dir/$java_identifier"
  set_candidate_default java relative "$old_java_identifier" "../java/$old_java_identifier"
  set_candidate_default maven relative "$old_maven_identifier" "../maven/$old_maven_identifier"
  write_sdkmanrc "java=$java_identifier" "maven=$maven_identifier"
  export FAKE_SDK_ENV_INSTALL_STATUS=17

  run_capture bash "$full_env_script" -- "$case_dir/payload" should-not-run
  assert_status 17 'full environment preserves sdk env install failure status after reconciliation'
  assert_candidate_default_state java "link:../java/$old_java_identifier" \
    'sdk failure still reconciles Java default'
  assert_candidate_default_state maven "link:../maven/$old_maven_identifier" \
    'sdk failure still reconciles Maven default'
  assert_file_empty "$FAKE_PAYLOAD_LOG" 'payload does not run after sdk env install failure'
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_full_env_invalid_authorization() {
  begin_case full_env_invalid_authorization
  local java_identifier='21.0.9-tem'
  local maven_identifier='3.9.8'

  create_java_candidate "$case_java_dir/$java_identifier"
  write_sdkmanrc "java=$java_identifier" "maven=$maven_identifier"

  run_capture bash "$full_env_script" --allow-default 'maven/invalid' -- "$case_dir/payload"
  assert_status 2 'invalid authorization candidate is rejected'
  assert_file_empty "$FAKE_SDK_LOG" 'invalid authorization blocks sdk invocation'
  assert_file_empty "$FAKE_PAYLOAD_LOG" 'invalid authorization blocks payload invocation'

  : > "$FAKE_SDK_LOG"
  : > "$FAKE_PAYLOAD_LOG"
  run_capture bash "$full_env_script" --allow-default maven --allow-default maven -- "$case_dir/payload"
  assert_status 2 'duplicate authorization candidate is rejected'
  assert_file_empty "$FAKE_SDK_LOG" 'duplicate authorization blocks sdk invocation'
  assert_file_empty "$FAKE_PAYLOAD_LOG" 'duplicate authorization blocks payload invocation'

  : > "$FAKE_SDK_LOG"
  : > "$FAKE_PAYLOAD_LOG"
  run_capture bash "$full_env_script" --allow-default gradle -- "$case_dir/payload"
  assert_status 2 'authorization for a candidate absent from .sdkmanrc is rejected'
  assert_file_empty "$FAKE_SDK_LOG" 'out-of-scope authorization blocks sdk invocation'
  assert_file_empty "$FAKE_PAYLOAD_LOG" 'out-of-scope authorization blocks payload invocation'
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

run_scenario() {
  local scenario_function="$1"
  local scenario_name="${scenario_function#scenario_}"
  if [[ -z "$scenario_filter" || "$scenario_filter" == "$scenario_name" ]]; then
    "$scenario_function"
  fi
}

run_scenario scenario_install_success_absolute_unchanged
run_scenario scenario_install_success_relative_unchanged
run_scenario scenario_install_success_absent
run_scenario scenario_install_failure_preserves_status
run_scenario scenario_install_failure_trailing_newline_default
run_scenario scenario_install_failure_option_like_default
run_scenario scenario_install_unexpected_default_from_absent
run_scenario scenario_install_unexpected_default_gnu_fallback
run_scenario scenario_install_restore_failure
run_scenario scenario_install_incomplete_candidate
run_scenario scenario_install_reserved_current
run_scenario scenario_install_concurrent_third_writer
run_scenario scenario_install_term_reconciles_default
run_scenario scenario_lock_live_owner_refusal
run_scenario scenario_lock_stale_owner_recovery
run_scenario scenario_lock_initialization_term_cleans_partial_lock
run_scenario scenario_restore_pre_cas_third_writer
run_scenario scenario_restore_gnu_fallback_third_writer
run_scenario scenario_run_existing_candidate_without_init
run_scenario scenario_run_empty_path_is_safe
run_scenario scenario_run_compound_bash_c_keeps_runner_jdk
run_scenario scenario_run_incomplete_candidate
run_scenario scenario_run_reserved_current
run_scenario scenario_run_relative_sdkman_dir_is_rejected
run_scenario scenario_run_invalid_identifiers_are_rejected
run_scenario scenario_run_java_probe_failure_blocks_payload
run_scenario scenario_lock_create_failure_is_not_type_error
run_scenario scenario_lock_regular_file_is_unsafe
run_scenario scenario_lock_symlink_is_unsafe
run_scenario scenario_full_env_atomic_sdkmanrc_replace_is_rejected_and_reconciled
run_scenario scenario_full_env_term_reconciles_operation_owned_defaults
run_scenario scenario_full_env_success_allows_authorized_default
run_scenario scenario_full_env_restores_unapproved_defaults
run_scenario scenario_full_env_cleanup_uses_pre_sdk_tools
run_scenario scenario_full_env_concurrent_third_writer
run_scenario scenario_full_env_malformed_sdkmanrc
run_scenario scenario_full_env_unsupported_current
run_scenario scenario_full_env_restore_failure
run_scenario scenario_full_env_sdk_failure_blocks_payload
run_scenario scenario_full_env_invalid_authorization

if [[ "$scenario_count" -eq 0 ]]; then
  printf 'Unknown scenario: %s\n' "$scenario_filter" >&2
  exit 2
fi

printf 'All %s sdkman-switch-jdk contract scenarios passed (scripts: %s)\n' "$scenario_count" "$scripts_dir"
