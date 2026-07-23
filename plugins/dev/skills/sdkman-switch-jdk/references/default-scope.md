# SDKMAN 永久 Java default 變更

只有在使用者明確要求變更或回復 SDKMAN Java default 時，才讀取本參考。一般 build、test 或單次命令使用 `SKILL.md` 的無狀態 `run-java.sh`。

## 記錄原始 default

在隔離的 Bash process 中載入 SDKMAN、停用本次初始化的 auto-env，並記錄 `java/current`：

```bash
bash -c '
  set -e -o pipefail
  unset SDKMAN_ENV
  export SDKMAN_OLD_PWD="$PWD"
  source "${SDKMAN_DIR:-$HOME/.sdkman}/bin/sdkman-init.sh"
  sdk version
  sdkman_switch_jdk_current="${SDKMAN_CANDIDATES_DIR}/java/current"
  if [[ -L "$sdkman_switch_jdk_current" ]]; then
    printf "SDKMAN Java default state: link-hex:"
    LC_ALL=C readlink -n "$sdkman_switch_jdk_current" | \
      LC_ALL=C od -An -v -tx1 | LC_ALL=C tr -d "[:space:]"
    printf "\n"
  elif [[ -e "$sdkman_switch_jdk_current" ]]; then
    printf "ERROR: current is not a symlink: %s\n" "$sdkman_switch_jdk_current" >&2
    exit 1
  else
    printf "SDKMAN Java default state: absent\n"
  fi
'
```

將 `SDKMAN Java default state:` 後的完整值逐字保存為 `<previous-default-state>`；值只會是 `link-hex:<raw-readlink-target 的逐 byte 十六進位>` 或 `absent`。編碼避免 shell command substitution 遺失 target 尾端 newline，也讓 state 能安全地作為單一 argv 傳遞。若初始化失敗，停止並說明 SDKMAN 尚未安裝或不可用；取得同意前不安裝 SDKMAN。

## 設定永久 default

將 identifier 與保存的 state 分別作為單一 argv 傳入。設定前再次確認 default 沒有漂移，然後保存輸出的 `<created-default-state>`：

```bash
bash -c '
  set -e -o pipefail
  unset SDKMAN_ENV
  export SDKMAN_OLD_PWD="$PWD"
  source "${SDKMAN_DIR:-$HOME/.sdkman}/bin/sdkman-init.sh"
  sdkman_switch_jdk_current="${SDKMAN_CANDIDATES_DIR}/java/current"
  sdkman_switch_jdk_link_state() {
    printf "link-hex:"
    LC_ALL=C readlink -n "$1" | LC_ALL=C od -An -v -tx1 | \
      LC_ALL=C tr -d "[:space:]" || return 1
    printf "\n"
  }
  sdkman_switch_jdk_default_state() {
    if [[ -L "$sdkman_switch_jdk_current" ]]; then
      sdkman_switch_jdk_link_state "$sdkman_switch_jdk_current"
    elif [[ -e "$sdkman_switch_jdk_current" ]]; then
      printf "unsupported\n"
    else
      printf "absent\n"
    fi
  }
  sdkman_switch_jdk_before="$(sdkman_switch_jdk_default_state)"
  if [[ "$sdkman_switch_jdk_before" != "$2" ]]; then
    printf "Refusing to change a default that drifted.\nExpected: %s\nActual:   %s\n" \
      "$2" "$sdkman_switch_jdk_before" >&2
    exit 1
  fi
  sdk default java "$1"
  sdkman_switch_jdk_created="$(sdkman_switch_jdk_default_state)"
  if [[ "$sdkman_switch_jdk_created" != link-hex:* ]]; then
    printf "SDKMAN did not create a Java default symlink.\n" >&2
    exit 1
  fi
  printf "Created default state: %s\n" "$sdkman_switch_jdk_created"
' bash <identifier> <previous-default-state>

bash -c '
  set -e -o pipefail
  unset SDKMAN_ENV
  export SDKMAN_OLD_PWD="$PWD"
  source "${SDKMAN_DIR:-$HOME/.sdkman}/bin/sdkman-init.sh"
  java -version 2>&1
  command -v java
'
```

不要將 state 當作 SDKMAN identifier，也不要用 `eval`。永久變更期間不得並行執行其他會改寫 `java/current` 的 SDKMAN 操作。

## 依要求回復

只在使用者要求回復時執行以下命令。它先要求目前 state 逐字等於 `<created-default-state>`，避免覆蓋後續變更；原本有 default 時，以 `java` 目錄內的暫存 symlink 原子還原 raw target，原本為 `absent` 時則移除本次建立的 symlink：

```bash
bash -c '
  set -e -o pipefail
  unset SDKMAN_ENV
  export SDKMAN_OLD_PWD="$PWD"
  source "${SDKMAN_DIR:-$HOME/.sdkman}/bin/sdkman-init.sh"
  sdkman_switch_jdk_java_dir="${SDKMAN_CANDIDATES_DIR}/java"
  sdkman_switch_jdk_current="${SDKMAN_CANDIDATES_DIR}/java/current"
  sdkman_switch_jdk_link_state() {
    printf "link-hex:"
    LC_ALL=C readlink -n "$1" | LC_ALL=C od -An -v -tx1 | \
      LC_ALL=C tr -d "[:space:]" || return 1
    printf "\n"
  }
  sdkman_switch_jdk_default_state() {
    if [[ -L "$sdkman_switch_jdk_current" ]]; then
      sdkman_switch_jdk_link_state "$sdkman_switch_jdk_current"
    elif [[ -e "$sdkman_switch_jdk_current" ]]; then
      printf "unsupported\n"
    else
      printf "absent\n"
    fi
  }
  sdkman_switch_jdk_decode_link_state() {
    local sdkman_switch_jdk_encoded="${1#link-hex:}"
    local sdkman_switch_jdk_escaped=""
    if [[ "$1" != link-hex:* || -z "$sdkman_switch_jdk_encoded" || \
          $(( ${#sdkman_switch_jdk_encoded} % 2 )) -ne 0 || \
          ! "$sdkman_switch_jdk_encoded" =~ ^[[:xdigit:]]+$ ]]; then
      return 1
    fi
    while [[ -n "$sdkman_switch_jdk_encoded" ]]; do
      sdkman_switch_jdk_escaped="${sdkman_switch_jdk_escaped}\\x${sdkman_switch_jdk_encoded:0:2}"
      sdkman_switch_jdk_encoded="${sdkman_switch_jdk_encoded:2}"
    done
    printf -v sdkman_switch_jdk_decoded_target "%b" \
      "$sdkman_switch_jdk_escaped"
  }
  sdkman_switch_jdk_expected="$1"
  sdkman_switch_jdk_previous="$2"
  if [[ "$sdkman_switch_jdk_expected" != link-hex:* ]] || \
     [[ "$sdkman_switch_jdk_previous" != link-hex:* && \
        "$sdkman_switch_jdk_previous" != absent ]]; then
    printf "Invalid saved default state.\n" >&2
    exit 2
  fi
  sdkman_switch_jdk_actual="$(sdkman_switch_jdk_default_state)"
  if [[ "$sdkman_switch_jdk_actual" != "$sdkman_switch_jdk_expected" ]]; then
    printf "Refusing to overwrite a default that drifted.\nExpected: %s\nActual:   %s\n" \
      "$sdkman_switch_jdk_expected" "$sdkman_switch_jdk_actual" >&2
    exit 1
  fi
  if [[ "$sdkman_switch_jdk_previous" == absent ]]; then
    unlink "$sdkman_switch_jdk_current"
  else
    if ! sdkman_switch_jdk_decode_link_state "$sdkman_switch_jdk_previous"; then
      printf "Invalid encoded previous default state.\n" >&2
      exit 2
    fi
    sdkman_switch_jdk_previous_target="$sdkman_switch_jdk_decoded_target"
    sdkman_switch_jdk_temp_dir="$(
      mktemp -d "$sdkman_switch_jdk_java_dir/.sdkman-switch-jdk-restore.XXXXXX"
    )"
    sdkman_switch_jdk_temp_link="$sdkman_switch_jdk_temp_dir/current"
    sdkman_switch_jdk_cleanup() {
      if [[ -L "${sdkman_switch_jdk_temp_link:-}" ]]; then
        unlink "$sdkman_switch_jdk_temp_link" 2>/dev/null || true
      fi
      if [[ -d "${sdkman_switch_jdk_temp_dir:-}" ]]; then
        rmdir "$sdkman_switch_jdk_temp_dir" 2>/dev/null || true
      fi
    }
    trap sdkman_switch_jdk_cleanup EXIT
    ln -s -- "$sdkman_switch_jdk_previous_target" "$sdkman_switch_jdk_temp_link"
    if [[ ! -L "$sdkman_switch_jdk_temp_link" ]] || \
       [[ "$(sdkman_switch_jdk_link_state "$sdkman_switch_jdk_temp_link")" != \
          "$sdkman_switch_jdk_previous" ]]; then
      printf "Could not create the exact rollback symlink.\n" >&2
      exit 1
    fi
    if [[ "$(sdkman_switch_jdk_default_state)" != \
          "$sdkman_switch_jdk_expected" ]]; then
      printf "Refusing to overwrite a default that drifted during rollback.\n" >&2
      exit 1
    fi
    if mv -fh "$sdkman_switch_jdk_temp_link" \
         "$sdkman_switch_jdk_current" 2>/dev/null; then
      :
    elif [[ -L "$sdkman_switch_jdk_temp_link" ]] && \
         mv -Tf "$sdkman_switch_jdk_temp_link" \
           "$sdkman_switch_jdk_current" 2>/dev/null; then
      :
    else
      printf "Could not atomically restore the Java default.\n" >&2
      exit 1
    fi
    rmdir "$sdkman_switch_jdk_temp_dir"
    sdkman_switch_jdk_temp_dir=
    sdkman_switch_jdk_temp_link=
    trap - EXIT
  fi
  sdkman_switch_jdk_actual="$(sdkman_switch_jdk_default_state)"
  if [[ "$sdkman_switch_jdk_actual" != "$sdkman_switch_jdk_previous" ]]; then
    printf "Java default rollback verification failed.\nExpected: %s\nActual:   %s\n" \
      "$sdkman_switch_jdk_previous" "$sdkman_switch_jdk_actual" >&2
    exit 1
  fi
  printf "Restored default state: %s\n" "$sdkman_switch_jdk_actual"
' bash <created-default-state> <previous-default-state>
```

**完成條件：**永久 default 的建立與驗證成功，並回報 `<previous-default-state>`、`<created-default-state>` 及可逐 byte 回復的命令。若 default 在任一比較點漂移，保留外部狀態並停止。
