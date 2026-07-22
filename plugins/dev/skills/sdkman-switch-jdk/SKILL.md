---
name: sdkman-switch-jdk
description: Always use for any Java/JDK version issue, including selecting, finding, installing, or switching a JDK; Java version mismatches or compatibility errors; JAVA_HOME or toolchain conflicts; and Maven, Gradle, project, CI, or local-runtime JDK differences. Resolve the required JDK safely with SDKMAN without unintentionally changing the default, even when SDKMAN availability is not yet confirmed.
---

# SDKMAN 切換 JDK

採用最小範圍：預設只在執行實際命令的 shell 暫時切換 Java。只有使用者明確要求時，才變更 SDKMAN default、`.sdkmanrc` 或完整專案環境。

## 不變條件

- 先將需求解析成唯一的完整 SDKMAN identifier，再變更環境。
- 將使用者明確指定的版本置於專案推論之前；衝突時揭露兩者。
- 將 Java-only 要求限制在 Java，不連帶安裝或切換其他 SDK。
- 在變更前記錄 default 狀態；除非使用者明確要求，完成後必須完全相同。
- 將初始化、切換、驗證與實際命令放在同一個 shell。
- 以 `java -version`、`command -v java` 與實際命令結果作為完成證據。

## 工作流程

### 1. 解析 JDK 需求

依下列順序找出需求：

1. 使用者明確指定的 identifier、主版本或 distribution。
2. `.sdkmanrc` 的 `java=` 與 `.java-version`。
3. Gradle Java toolchain、Maven Toolchains 或 Maven Enforcer `requireJavaVersion`。
4. 專案文件、CI 設定與可重現的 build/test 錯誤。

當目標需要從 `.sdkmanrc` 解析、需要修改該檔，或需要套用完整 SDKMAN 環境時，先計算其中有效的 `java=` 項目。沒有時繼續找其他證據；只有一個時使用它；超過一個時列出每個衝突並停止，要求使用者選定或授權修正，不得任選其中一筆。若使用者已明確指定一次性的完整 identifier，則回報 `.sdkmanrc` 衝突後仍可使用隔離 runner 繼續，因為該路徑不會套用 auto-env。

將 Maven `source`、`target`、`release` 與 Gradle `sourceCompatibility`、`targetCompatibility` 視為編譯相容性，不直接當作執行 Maven/Gradle 所需的 JDK。將一般性的 `<java.version>` 視為線索，並用 toolchain、文件或錯誤訊息確認其語意。

若使用者要求一次性 JDK 與專案 metadata 衝突，採用使用者指定值並回報衝突。若要求持久化變更，先說明將修改哪個狀態。

**完成條件：**取得一個有來源證據的完整 identifier，或取得仍需解析的唯一主版本與 distribution 約束。

### 2. 初始化並記錄原始狀態

在隔離的 Bash process 中載入 SDKMAN、停用本次初始化的 auto-env、檢查目前 Java，並記錄 `java/current`：

```bash
bash -c '
  set -e -o pipefail
  unset SDKMAN_ENV
  export SDKMAN_OLD_PWD="$PWD"
  source "${SDKMAN_DIR:-$HOME/.sdkman}/bin/sdkman-init.sh"
  sdk version
  if sdkman_switch_jdk_java="$(command -v java 2>/dev/null)"; then
    printf "java: %s\n" "$sdkman_switch_jdk_java"
    if ! java -version 2>&1; then
      printf "WARNING: active java could not report its version.\n" >&2
    fi
  else
    printf "Active java: absent\n"
  fi
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

**完成條件：**SDKMAN 可用、目前 Java 已觀察、default 已記為完整 symlink target 或 `absent`。

### 3. 解析完整 identifier

列出已安裝版本：

```bash
bash -c '
  set -e -o pipefail
  unset SDKMAN_ENV
  export SDKMAN_OLD_PWD="$PWD"
  source "${SDKMAN_DIR:-$HOME/.sdkman}/bin/sdkman-init.sh"
  sdkman_switch_jdk_java_dir="${SDKMAN_CANDIDATES_DIR}/java"
  if [[ -d "$sdkman_switch_jdk_java_dir" ]]; then
    find "$sdkman_switch_jdk_java_dir" -mindepth 1 -maxdepth 1 \
      \( -type d -o -type l \) ! -name current -exec basename {} \; | \
      LC_ALL=C sort
  else
    printf "Installed SDKMAN Java candidates: none\n"
  fi
'
```

依以下規則解析：

- metadata 或使用者已給完整 identifier 時，使用該值。
- 只有主版本時，先沿用使用者、專案 metadata 或目前 default 明確指出的 distribution。
- 只有一個符合主版本與 distribution 的已安裝版本時，使用它。
- 多個版本仍符合時，列出它們並要求選定 distribution 或 patch；不得取清單第一筆。
- 沒有已安裝版本時，查看 `sdk list java` 並選定一個完整可用 identifier；僅在使用者接受 SDKMAN 預設 distribution 時代為選擇 Temurin。

將 `sdk list java` 當作顯示資料；不要用 ANSI 輸出判斷目前生效的 Java。

**完成條件：**只剩一個完整 identifier，例如 `21.0.9-tem`。

### 4. 必要時安全安裝

若 identifier 尚未安裝，執行此 skill 目錄中的安裝 script；將 `<skill-dir>` 解析為包含本檔案的目錄：

```bash
bash <skill-dir>/scripts/install-java.sh <identifier>
```

script 會對 SDKMAN 的 default 提示明確回答 `n`，並驗證安裝前後的 `java/current` 完全相同。不要改寫成 `SDKMAN_AUTO_ANSWER=true sdk install ...`。

**完成條件：**`${SDKMAN_CANDIDATES_DIR}/java/<identifier>` 存在，且 default 狀態與步驟 2 完全相同。

### 5. 套用最小範圍並執行

#### 暫時切換，預設分支

使用此 skill 的 runner 在同一個 Bash process 完成安全初始化、切換、驗證與實際命令。runner 在既有 default 時使用 `sdk use`，接著在所有情況下將精確 candidate 的 `bin` 放到 `PATH` 最前方；default 為 `absent` 時不建立 `java/current`：

```bash
bash <skill-dir>/scripts/run-java.sh <identifier> -- <actual-command>
```

暫時分支必須一律呼叫這個 runner；這是唯一允許的入口。不得以裸 `sdk use`、自行 source 的 subshell 或手動設定 `JAVA_HOME` 取代，因為 runner 同時負責阻止 auto-env、保留 default、處理原本沒有 default 的狀態，以及維持 command argv 邊界。

需要 compound command 時，將它明確交給 Bash，例如 `-- bash -lc 'mvn test && mvn package'`。不要自行拼接或 `eval` 使用者輸入。

#### 永久 default，僅限明確要求

使用步驟 2 保存的 `<previous-default-state>`。將 identifier 與 state 分別作為單一 argv 傳入，不得把 state 當作 SDKMAN identifier，也不得用 `eval`。設定前再次確認 default 沒有漂移，然後保存輸出的 `<created-default-state>`：

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

只在使用者要求回復時執行以下命令。它先要求目前 state 逐字等於 `<created-default-state>`，避免覆蓋後續變更；原本有 default 時，以 `java` 目錄內的暫存 symlink 原子還原 raw target，原本為 `absent` 時則移除本次建立的 symlink。兩個 state 都必須分別作為單一 argv 傳入：

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

#### 專案或完整環境

當使用者明確要求修改 `.sdkmanrc`，或要求套用其中所有 SDK 時，讀取 [project-scope.md](references/project-scope.md)。一般 Java-only 要求留在暫時分支。

**完成條件：**同一 shell 中的版本、路徑與完整 identifier 相符，且使用者要求的 build/test/command 成功；任何持久化狀態都有具體回復方式。

### 6. 回報結果

回報以下證據：

1. 選用的完整 identifier 與來源。
2. 套用範圍：暫時、default、`.sdkmanrc` 或完整專案環境。
3. `java -version`、`command -v java` 與實際命令結果。
4. 任何持久化變更及其具體回復命令。

核心流程失敗時才讀取 [troubleshooting.md](references/troubleshooting.md)，並在替代路徑上重新滿足相同完成條件。
