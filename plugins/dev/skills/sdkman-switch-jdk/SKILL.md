---
name: sdkman-switch-jdk
description: Always use for any Java/JDK version issue, including selecting, finding, installing, or switching a JDK; Java version mismatches or compatibility errors; JAVA_HOME or toolchain conflicts; and Maven, Gradle, project, CI, or local-runtime JDK differences. Resolve the required JDK safely with SDKMAN without unintentionally changing the default, even when SDKMAN availability is not yet confirmed.
---

# SDKMAN 切換 JDK

採用最小範圍：已安裝的 exact JDK 預設只在實際命令的 process 暫時生效，不初始化 SDKMAN、不呼叫 `sdk use`、不讀寫 default，也不取得 default-state lock。只有需要安裝、永久 default 或完整專案環境時，才進入有狀態流程。

## 不變條件

- 先將需求解析成唯一的完整 SDKMAN identifier，再套用環境。
- 使用者明確指定的版本優先於專案推論；衝突時揭露兩者。
- Java-only 要求只處理 Java，不連帶安裝或切換其他 SDK。
- 已安裝的 exact candidate 一律使用 bundled `run-java.sh`；不要 source SDKMAN、裸用 `sdk use` 或手動設定 `JAVA_HOME`。
- 會改變 SDKMAN 狀態的流程必須保護並驗證 default；除非使用者明確要求，完成後必須與執行前完全相同。
- 使用 `bash -c` 執行 compound command；不要使用會重新讀取 profile 的 login shell。
- 以 `java -version`、`command -v java` 與實際命令結果作為完成證據。

## 工作流程

### 1. 解析 JDK 需求

依下列順序找出需求：

1. 使用者明確指定的 identifier、主版本或 distribution。
2. `.sdkmanrc` 的 `java=` 與 `.java-version`。
3. Gradle Java toolchain、Maven Toolchains 或 Maven Enforcer `requireJavaVersion`。
4. 專案文件、CI 設定與可重現的 build/test 錯誤。

當目標需要從 `.sdkmanrc` 解析、修改該檔或套用完整 SDKMAN 環境時，先計算有效的 `java=` 項目。沒有時繼續找其他證據；只有一個時使用它；超過一個時列出衝突並停止，不得任選。若使用者明確指定一次性的完整 identifier，回報 `.sdkmanrc` 衝突後仍可使用隔離 runner，因為該路徑不套用 auto-env。

Maven `source`、`target`、`release` 與 Gradle `sourceCompatibility`、`targetCompatibility` 是編譯相容性，不直接等同於執行 Maven/Gradle 所需的 JDK。一般性的 `<java.version>` 只是線索，需由 toolchain、文件或實際錯誤確認。

若使用者要求的一次性 JDK 與專案 metadata 衝突，採用使用者指定值並回報衝突。若要求持久化，先說明將修改哪個狀態。

**完成條件：**取得一個有來源證據的完整 identifier，或取得唯一的主版本與 distribution 約束。

### 2. 不初始化 SDKMAN，先找已安裝版本

直接檢查 SDKMAN candidate tree；不要為了列目錄先 source `sdkman-init.sh`：

```bash
bash -c '
  set -e -o pipefail
  sdkman_switch_jdk_root="${SDKMAN_DIR:-${HOME:?HOME is not set}/.sdkman}"
  case "$sdkman_switch_jdk_root" in
    /*) ;;
    *) printf "SDKMAN_DIR must be an absolute path: %s\n" "$sdkman_switch_jdk_root" >&2; exit 1 ;;
  esac
  if [[ ! -d "$sdkman_switch_jdk_root" ]]; then
    printf "Installed SDKMAN Java candidates: none (SDKMAN directory unavailable)\n"
    exit 0
  fi
  sdkman_switch_jdk_root="$(cd "$sdkman_switch_jdk_root" && pwd -P)"
  sdkman_switch_jdk_java_dir="$sdkman_switch_jdk_root/candidates/java"
  if [[ -d "$sdkman_switch_jdk_java_dir" ]]; then
    find "$sdkman_switch_jdk_java_dir" -mindepth 1 -maxdepth 1 \
      \( -type d -o -type l \) ! -name current -exec basename {} \; | \
      LC_ALL=C sort
  else
    printf "Installed SDKMAN Java candidates: none\n"
  fi
'
```

依下列規則收斂 identifier：

- metadata 或使用者已給完整 identifier 時，使用該值。
- 只有主版本時，先沿用使用者、專案 metadata 或目前 default 明確指出的 distribution。
- 只有一個符合主版本與 distribution 的已安裝版本時，使用它。
- 多個版本仍符合時，列出並要求選定 distribution 或 patch；不得取清單第一筆。
- 沒有已安裝版本時，進入步驟 4；不要從 ANSI 格式的 `sdk list java` 推論目前生效版本。

**完成條件：**只剩一個完整 identifier，例如 `21.0.9-tem`。

### 3. 已安裝 exact candidate：直接執行

將 `<skill-dir>` 解析為包含本檔案的目錄，使用唯一的暫時執行入口：

```bash
bash <skill-dir>/scripts/run-java.sh <identifier> -- <actual-command> [args...]
```

runner 只使用 `${SDKMAN_DIR:-$HOME/.sdkman}/candidates/java/<identifier>`，忽略外部的 `SDKMAN_CANDIDATES_DIR`。它會驗證 absolute SDKMAN root、candidate 與 `bin/java`，再設定 exact `JAVA_HOME`／`PATH`、執行版本探測並 `exec` payload；它不讀取 `java/current`，因此 malformed 或不存在的 default 不影響此分支。

需要 compound command 時，明確傳給 non-login Bash，例如：

```bash
bash <skill-dir>/scripts/run-java.sh <identifier> -- \
  bash -c 'mvn test && mvn package'
```

不要改用 `bash -lc`；login shell 會重新讀取 profile，可能覆寫 runner 選定的 `JAVA_HOME` 與 `PATH`。不要拼接或 `eval` 使用者輸入。

這條 fast path 刻意不載入 SDKMAN extensions/native override，也不和同一使用者對 candidate tree 的替換序列化。只對已完整安裝、受信任且穩定的 exact candidate 使用；若同一 identifier 正在安裝或被替換，等它完成後再執行。

**完成條件：**runner 回報的版本與路徑符合 identifier，且實際命令成功。若已完成使用者要求，直接進入步驟 6。

### 4. 必要時解析並安全安裝

只有已安裝清單無法收斂或 exact candidate 尚未安裝時，才載入 SDKMAN。若 init 不存在，停止並在安裝 SDKMAN 前取得同意：

```bash
bash -c '
  set -e -o pipefail
  unset SDKMAN_ENV
  export SDKMAN_OLD_PWD="$PWD"
  source "${SDKMAN_DIR:-$HOME/.sdkman}/bin/sdkman-init.sh"
  sdk list java
'
```

從顯示結果選定完整 identifier；只有使用者接受 SDKMAN 預設 distribution 時，才代為選擇 Temurin。不要用 `head -1` 猜版本。

執行 bundled 安裝 script：

```bash
bash <skill-dir>/scripts/install-java.sh <identifier>
```

script 會取得 state lock、對 default 提示明確回答 `n`，並驗證安裝前後的 `java/current` 完全相同。不要改寫成 `SDKMAN_AUTO_ANSWER=true sdk install ...`。安裝成功後回到步驟 3，以無狀態 runner 執行實際命令。

**完成條件：**exact candidate 的 `bin/java` 存在且可執行，SDKMAN default 未改變，實際命令由步驟 3 驗證成功。

### 5. 只有明確要求時才擴大範圍

- 永久變更或回復 SDKMAN Java default：讀取 [default-scope.md](references/default-scope.md)。
- 修改 `.sdkmanrc` 或套用其中所有 SDK：讀取 [project-scope.md](references/project-scope.md)。

不要因一般 Java build/test 需求載入這兩份參考。

### 6. 回報結果

回報以下證據：

1. 選用的完整 identifier 與來源。
2. 套用範圍：無狀態暫時執行、安裝、default、`.sdkmanrc` 或完整專案環境。
3. `java -version`、`command -v java` 與實際命令結果。
4. 任何持久化變更及其具體回復命令。

核心流程失敗時才讀取 [troubleshooting.md](references/troubleshooting.md)，並在替代路徑上重新滿足相同完成條件。
