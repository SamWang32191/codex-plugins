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
if [[ ! -r "$install_script" || ! -r "$run_script" ]]; then
  printf 'Missing SDKMAN switch scripts in: %s\n' "$scripts_dir" >&2
  exit 1
fi

original_path="$PATH"
real_mv="$(command -v mv)"
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
fake_bin=''
shadow_bin=''
last_status=0
scenario_count=0

cleanup() {
  local cleanup_status="$?"
  trap - EXIT HUP INT TERM
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

assert_default_state() {
  local expected="$1"
  local message="$2"
  assert_eq "$expected" "$(default_state)" "$message"
}

create_java_candidate() {
  local candidate="$1"
  mkdir -p "$candidate/bin"
  {
    printf '%s\n' '#!/usr/bin/env bash'
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
    printf '%s\n' 'fake_sdk_set_current() {'
    printf '%s\n' '  local fake_target="$1"'
    printf '%s\n' '  if [[ -L "$FAKE_CURRENT_PATH" || -e "$FAKE_CURRENT_PATH" ]]; then unlink "$FAKE_CURRENT_PATH"; fi'
    printf '%s\n' '  ln -s -- "$fake_target" "$FAKE_CURRENT_PATH"'
    printf '%s\n' '}'
    printf '%s\n' 'sdk() {'
    printf '%s\n' '  {'
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
    printf '%s\n' '      fake_identifier="${3-}"'
    printf '%s\n' '      fake_candidate="${SDKMAN_CANDIDATES_DIR}/java/${fake_identifier}"'
    printf '%s\n' '      fake_install_answer="<none>"'
    printf '%s\n' '      if IFS= read -r fake_install_answer; then :; fi'
    printf '%s\n' '      printf "sdk stdin=<%s>\\n" "$fake_install_answer" >> "${FAKE_SDK_LOG:?}"'
    printf '%s\n' '      if [[ "${FAKE_SDK_INSTALL_CREATE:-yes}" == yes ]]; then fake_sdk_write_candidate "$fake_candidate"; fi'
    printf '%s\n' '      case "${FAKE_SDK_INSTALL_MUTATE:-none}" in'
    printf '%s\n' '        target_abs) fake_sdk_set_current "$fake_candidate" ;;'
    printf '%s\n' '        target_rel) fake_sdk_set_current "$fake_identifier" ;;'
    printf '%s\n' '        none) : ;;'
    printf '%s\n' '        *) printf "unknown install mutation: %s\\n" "${FAKE_SDK_INSTALL_MUTATE}" >&2; return 99 ;;'
    printf '%s\n' '      esac'
    printf '%s\n' '      return "${FAKE_SDK_INSTALL_STATUS:-0}"'
    printf '%s\n' '      ;;'
    printf '%s\n' '    use)'
    printf '%s\n' '      fake_identifier="${3-}"'
    printf '%s\n' '      fake_candidate="${SDKMAN_CANDIDATES_DIR}/java/${fake_identifier}"'
    printf '%s\n' '      case "${FAKE_SDK_USE_MUTATE:-none}" in'
    printf '%s\n' '        target_abs) fake_sdk_set_current "$fake_candidate" ;;'
    printf '%s\n' '        target_rel) fake_sdk_set_current "$fake_identifier" ;;'
    printf '%s\n' '        none) : ;;'
    printf '%s\n' '        *) printf "unknown use mutation: %s\\n" "${FAKE_SDK_USE_MUTATE}" >&2; return 98 ;;'
    printf '%s\n' '      esac'
    printf '%s\n' '      return "${FAKE_SDK_USE_STATUS:-0}"'
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
    printf '%s\n' 'case "${FAKE_MV_MODE:-bsd}" in'
    printf '%s\n' '  bsd) [[ "${1-}" == "-fh" ]] || exit 66 ;;'
    printf '%s\n' '  gnu) if [[ "${1-}" == "-fh" ]]; then exit 64; fi; [[ "${1-}" == "-Tf" ]] || exit 65 ;;'
    printf '%s\n' '  fail) exit 75 ;;'
    printf '%s\n' '  *) exit 76 ;;'
    printf '%s\n' 'esac'
    printf '%s\n' 'mv_source="${2-}"'
    printf '%s\n' 'mv_destination="${3-}"'
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

begin_case() {
  case_name="$1"
  case_dir="$root_tmp/$case_name"
  case_java_dir="$case_dir/candidates/java"
  case_current="$case_java_dir/current"
  fake_bin="$case_dir/fake-bin"
  shadow_bin="$case_dir/shadow-bin"
  mkdir -p "$case_dir/sdkman/bin" "$case_java_dir" "$fake_bin" "$shadow_bin" "$case_dir/home"
  case_pwd="$(cd "$case_dir" && pwd)"

  export HOME="$case_dir/home"
  export SDKMAN_DIR="$case_dir/sdkman"
  export SDKMAN_CANDIDATES_DIR="$case_dir/candidates"
  export FAKE_CURRENT_PATH="$case_current"
  export FAKE_INIT_LOG="$case_dir/init.log"
  export FAKE_SDK_LOG="$case_dir/sdk.log"
  export FAKE_MV_LOG="$case_dir/mv.log"
  export FAKE_JAVA_LOG="$case_dir/java.log"
  export FAKE_PAYLOAD_LOG="$case_dir/payload.log"
  export FAKE_SHADOW_LOG="$case_dir/shadow.log"
  export FAKE_REAL_MV="$real_mv"
  export FAKE_SDK_INSTALL_STATUS=0
  export FAKE_SDK_INSTALL_CREATE=yes
  export FAKE_SDK_INSTALL_MUTATE=none
  export FAKE_SDK_USE_STATUS=0
  export FAKE_SDK_USE_MUTATE=none
  export FAKE_MV_MODE=bsd
  export FAKE_JAVA_STATUS=0
  export FAKE_PAYLOAD_STATUS=0
  export PATH="$fake_bin:$original_path"

  : > "$FAKE_INIT_LOG"
  : > "$FAKE_SDK_LOG"
  : > "$FAKE_MV_LOG"
  : > "$FAKE_JAVA_LOG"
  : > "$FAKE_PAYLOAD_LOG"
  : > "$FAKE_SHADOW_LOG"
  write_fake_init
  write_fake_mv
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
  export FAKE_SDK_INSTALL_MUTATE=target_abs
  export FAKE_MV_MODE=fail

  run_capture bash "$install_script" "$target_identifier"
  assert_status 1 'install restoration failure returns one'
  assert_default_state "link:$case_java_dir/$target_identifier" 'failed install restoration leaves observed changed default'
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

scenario_run_success_absolute_path_shadow_payload() {
  begin_case run_success_absolute_path_shadow_payload
  local old_identifier='17.0.9-tem'
  local target_identifier='21.0.9-tem'
  local payload_path="$case_dir/payload"
  create_java_candidate "$case_java_dir/$old_identifier"
  create_java_candidate "$case_java_dir/$target_identifier"
  set_default absolute "$old_identifier"
  write_shadow_java
  export PATH="$fake_bin:$shadow_bin:$original_path"
  export FAKE_SDK_USE_MUTATE=none
  export FAKE_PAYLOAD_STATUS=23

  run_capture bash "$run_script" "$target_identifier" -- "$payload_path" \
    'arg with spaces' '' 'glob*value?' '--' '--flag=value'
  assert_status 23 'payload exit status is preserved'
  assert_default_state "link:$case_java_dir/$old_identifier" 'absolute run default is restored'
  assert_file_empty "$FAKE_MV_LOG" 'unchanged absolute run does not call mv'
  assert_file_not_contains "$FAKE_SHADOW_LOG" 'shadow-java-called' 'candidate java wins over PATH shadow'
  assert_file_contains "$FAKE_JAVA_LOG" 'java arg[0]=<-version>' 'candidate java performs version probe'
  assert_file_contains "$FAKE_SDK_LOG" 'sdk arg[0]=<use>' 'existing default invokes sdk use'
  assert_file_contains "$case_dir/stderr" "java: $case_java_dir/$target_identifier/bin/java" 'run reports exact candidate java path'
  {
    printf 'payload JAVA_HOME=<%s>\n' "$case_java_dir/$target_identifier"
    printf 'payload PATH=<%s>\n' "$case_java_dir/$target_identifier/bin:$fake_bin:$shadow_bin:$original_path"
    printf 'payload java=<%s>\n' "$case_java_dir/$target_identifier/bin/java"
    printf 'payload argc=5\n'
    printf 'payload arg[0]=<arg with spaces>\n'
    printf 'payload arg[1]=<>\n'
    printf 'payload arg[2]=<glob*value?>\n'
    printf 'payload arg[3]=<-->\n'
    printf 'payload arg[4]=<--flag=value>\n'
  } > "$case_dir/expected-payload.log"
  if ! cmp "$case_dir/expected-payload.log" "$FAKE_PAYLOAD_LOG" >/dev/null 2>&1; then
    fail 'payload argv or environment was not preserved exactly'
  fi
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_run_success_relative_unchanged() {
  begin_case run_success_relative_unchanged
  local old_identifier='17.0.9-tem'
  local target_identifier='21.0.9-tem'
  create_java_candidate "$case_java_dir/$old_identifier"
  create_java_candidate "$case_java_dir/$target_identifier"
  set_default relative "$old_identifier" "../java/$old_identifier"
  export FAKE_SDK_USE_MUTATE=none
  export FAKE_MV_MODE=gnu

  run_capture bash "$run_script" "$target_identifier" -- "$case_dir/payload" simple
  assert_status 0 'relative run succeeds'
  assert_default_state "link:../java/$old_identifier" 'relative run default is restored exactly'
  assert_file_empty "$FAKE_MV_LOG" 'unchanged relative run does not call mv'
  assert_file_contains "$FAKE_PAYLOAD_LOG" 'payload arg[0]=<simple>' 'relative run invokes payload'
  assert_no_restore_temp_dirs
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_run_unexpected_default_gnu_fallback() {
  begin_case run_unexpected_default_gnu_fallback
  local old_identifier='17.0.9-tem'
  local target_identifier='21.0.9-tem'
  create_java_candidate "$case_java_dir/$old_identifier"
  create_java_candidate "$case_java_dir/$target_identifier"
  set_default relative "$old_identifier" "../java/$old_identifier"
  export FAKE_SDK_USE_MUTATE=target_rel
  export FAKE_MV_MODE=gnu

  run_capture bash "$run_script" "$target_identifier" -- "$case_dir/payload" should-not-run
  assert_status 1 'unexpected run default change is rejected after restore'
  assert_default_state "link:../java/$old_identifier" 'GNU run fallback restores the original relative default'
  assert_file_contains "$FAKE_MV_LOG" 'mv arg[0]=<-fh>' 'GNU run restore first probes BSD mv'
  assert_file_contains "$FAKE_MV_LOG" 'mv arg[0]=<-Tf>' 'GNU run restore uses -Tf fallback'
  assert_file_empty "$FAKE_PAYLOAD_LOG" 'payload does not run after unexpected default change'
  assert_file_contains "$case_dir/stderr" 'it was restored' 'unexpected run default change is reported'
  assert_no_restore_temp_dirs
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_run_success_absent() {
  begin_case run_success_absent
  local target_identifier='21.0.9-tem'
  create_java_candidate "$case_java_dir/$target_identifier"
  set_default absent "$target_identifier"

  run_capture bash "$run_script" "$target_identifier" -- "$case_dir/payload" absent
  assert_status 0 'run succeeds with absent default'
  assert_default_state absent 'absent run default remains absent'
  assert_file_empty "$FAKE_SDK_LOG" 'absent run skips sdk use'
  assert_file_empty "$FAKE_MV_LOG" 'absent run does not restore through mv'
  assert_file_contains "$FAKE_PAYLOAD_LOG" 'payload arg[0]=<absent>' 'absent run invokes payload'
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_run_use_failure_preserves_status() {
  begin_case run_use_failure_preserves_status
  local old_identifier='17.0.9-tem'
  local target_identifier='21.0.9-tem'
  create_java_candidate "$case_java_dir/$old_identifier"
  create_java_candidate "$case_java_dir/$target_identifier"
  set_default absolute "$old_identifier"
  export FAKE_SDK_USE_STATUS=19
  export FAKE_SDK_USE_MUTATE=target_abs

  run_capture bash "$run_script" "$target_identifier" -- "$case_dir/payload" should-not-run
  assert_status 19 'run failure preserves sdk use status'
  assert_default_state "link:$case_java_dir/$old_identifier" 'run failure restores original default'
  assert_file_empty "$FAKE_PAYLOAD_LOG" 'payload does not run after sdk use failure'
  assert_file_contains "$case_dir/stderr" 'status 19' 'run failure reports sdk use status'
  assert_file_contains "$FAKE_MV_LOG" 'mv arg[0]=<-fh>' 'run failure restores through BSD mv'
  assert_no_restore_temp_dirs
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_run_use_failure_byte_exact_default() {
  begin_case run_use_failure_byte_exact_default
  local target_identifier='21.0.9-tem'
  local raw_target=$'-f\n'
  create_java_candidate "$case_java_dir/$target_identifier"
  set_default relative unused "$raw_target"
  export FAKE_SDK_USE_STATUS=19
  export FAKE_SDK_USE_MUTATE=target_rel

  run_capture bash "$run_script" "$target_identifier" -- "$case_dir/payload" should-not-run
  assert_status 19 'run failure preserves status with option-like newline default target'
  assert_link_target_raw "$raw_target" "$case_current" 'run restores option-like newline target byte-for-byte'
  assert_path_absent "$case_dir/current" 'run rollback does not create a CWD current symlink'
  assert_file_empty "$FAKE_PAYLOAD_LOG" 'payload does not run after byte-exact sdk use failure'
  assert_file_contains "$FAKE_MV_LOG" 'mv arg[0]=<-fh>' 'byte-exact run restore uses BSD mv path'
  assert_no_restore_temp_dirs
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_run_restore_failure() {
  begin_case run_restore_failure
  local old_identifier='17.0.9-tem'
  local target_identifier='21.0.9-tem'
  create_java_candidate "$case_java_dir/$old_identifier"
  create_java_candidate "$case_java_dir/$target_identifier"
  set_default absolute "$old_identifier"
  export FAKE_SDK_USE_MUTATE=target_abs
  export FAKE_MV_MODE=fail

  run_capture bash "$run_script" "$target_identifier" -- "$case_dir/payload" should-not-run
  assert_status 1 'run restoration failure returns one'
  assert_default_state "link:$case_java_dir/$target_identifier" 'failed run restoration leaves observed changed default'
  assert_file_empty "$FAKE_PAYLOAD_LOG" 'payload does not run after restore failure'
  assert_file_contains "$case_dir/stderr" 'automatic restoration failed' 'run restore failure is reported'
  assert_no_restore_temp_dirs
  scenario_count=$((scenario_count + 1))
  printf 'PASS %s\n' "$case_name"
}

scenario_run_incomplete_candidate() {
  begin_case run_incomplete_candidate
  local old_identifier='17.0.9-tem'
  local target_identifier='21.0.9-tem'
  create_java_candidate "$case_java_dir/$old_identifier"
  create_incomplete_candidate "$case_java_dir/$target_identifier"
  set_default relative "$old_identifier" "../java/$old_identifier"

  run_capture bash "$run_script" "$target_identifier" -- "$case_dir/payload" should-not-run
  assert_status 1 'incomplete run candidate is rejected'
  assert_default_state "link:../java/$old_identifier" 'incomplete run candidate does not alter default'
  assert_file_empty "$FAKE_SDK_LOG" 'incomplete run candidate skips sdk use'
  assert_file_empty "$FAKE_PAYLOAD_LOG" 'payload does not run for incomplete candidate'
  assert_file_contains "$case_dir/stderr" 'not installed or is incomplete' 'incomplete run candidate is reported'
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
run_scenario scenario_run_success_absolute_path_shadow_payload
run_scenario scenario_run_success_relative_unchanged
run_scenario scenario_run_unexpected_default_gnu_fallback
run_scenario scenario_run_success_absent
run_scenario scenario_run_use_failure_preserves_status
run_scenario scenario_run_use_failure_byte_exact_default
run_scenario scenario_run_restore_failure
run_scenario scenario_run_incomplete_candidate
run_scenario scenario_run_reserved_current

if [[ "$scenario_count" -eq 0 ]]; then
  printf 'Unknown scenario: %s\n' "$scenario_filter" >&2
  exit 2
fi

printf 'All %s sdkman-switch-jdk contract scenarios passed (scripts: %s)\n' "$scenario_count" "$scripts_dir"
