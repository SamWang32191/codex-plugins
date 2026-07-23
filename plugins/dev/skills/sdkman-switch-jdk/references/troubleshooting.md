# SDKMAN JDK 疑難排解

只有在核心安裝或 runner 流程失敗時，才讀取本參考。

## 驗證目前生效的 Java

以 `java -version` 與 `command -v java` 作為可觀察的真相。SDKMAN 5.20.0 在暫時 `sdk use` 後，`sdk current java` 仍可能回報 default；不要用它驗證目前 shell。

SDKMAN 輸出可能包含 ANSI escape。將 `sdk list java` 當作顯示資料，不要解析它來推論生效版本。

## 維持 default 不變

`scripts/run-java.sh` 直接使用 `${SDKMAN_DIR:-$HOME/.sdkman}/candidates/java/<identifier>`，不載入 SDKMAN、不呼叫 `sdk use`、不讀寫 `java/current`，也不取得 default-state lock。它會將 exact candidate 的 `bin` 放到 `PATH` 最前方；caller 的 `PATH` 為空時不加入會代表目前目錄的空 segment。這條路徑刻意略過 SDKMAN extensions/native override，且不與同一 candidate 的並行替換序列化。

`scripts/install-java.sh` 會預先設定 `USE=n` 並對提示送入 `n`，同時比較安裝前後的 `java/current`。`scripts/run-sdkman-env.sh` 會一次解析並驗證 `.sdkmanrc`，再以記憶體 candidate 清單逐項執行 `sdk install` 與 `sdk use`；它不讓 SDKMAN 第二次讀取檔案，並對每個 candidate 執行 raw-state 保護。

這兩個會改變 SDKMAN 狀態的 bundled runner 共用 `${SDKMAN_CANDIDATES_DIR}/.sdkman-switch-jdk.lock`，讓 SDKMAN 操作與 reconciliation 不會彼此交錯。live owner 會使新呼叫 fail fast；metadata 完整、同一 EUID 且 PID 已不存在的 stale lock 會在重新核對後回收。metadata 不完整、ownership 不符或 PID 仍存活時一律保留 lock 並停止；先確認沒有相關 runner 後再人工檢查，不要直接遞迴刪除。

此 lock 是 bundled runner 間的合作式協調邊界。不要在 runner 執行期間以裸 `sdk default`、手動改寫 `current` 或其他不取得同一 lock 的流程並行變更 default；runner 會在每次還原寫入前重查漂移，但 portable Bash 無法把 state comparison 與 filesystem mutation 合併成單一 kernel operation。`HUP`、`INT` 與 `TERM` 會先執行相同 reconciliation 再釋放 lock；`SIGKILL` 或系統崩潰無法由 shell trap 處理，後續呼叫只會依完整 owner metadata 的 stale-lock 規則回收 lock，不會猜測或覆寫 default。

`run-java.sh` 已同時設定 `JAVA_HOME` 與 `PATH`。若它回報 active Java 不符，檢查 `${SDKMAN_DIR:-$HOME/.sdkman}/candidates/java/<identifier>/bin/java` 是否為可執行的 regular file。不要將 `JAVA_HOME` 指向 `java/current`；該 symlink 代表 default，不一定是要求的 identifier。compound command 使用 `bash -c`；`bash -lc` 可能載入 profile 並覆寫這兩個值。

## 失敗處理

| 觀察 | 動作 |
| --- | --- |
| exact candidate 已安裝但 SDKMAN init script 不存在 | 直接使用 `run-java.sh`；無狀態分支不需要 init。 |
| 需要安裝／完整環境但 SDKMAN init script 不存在 | 停止並在安裝 SDKMAN 前取得同意。 |
| 沒有唯一 identifier 符合主版本 | 列出候選並要求選定 distribution；不要取清單第一筆。 |
| `Stop! <id> is not available.` | 重新查看 `sdk list java` 並選定完整可用 identifier。 |
| runner 回報 active Java 不符 | 檢查 candidate 的 `bin/java` 與 shell 執行環境；不要繞過 runner，修正原因後重跑。 |
| stateful runner 回報無法建立 lock | 確認 lock parent 存在且可寫；不要把 absent path 當成 stale lock。 |
| stateful runner 回報 unsafe lock path | 保留該 regular file 或 symlink，確認來源後人工處理；runner 不會覆寫或刪除。 |
| runner 回報 project `.sdkmanrc` 在 activation 期間改變 | 保留並檢查並行修改；runner 只會執行已驗證的記憶體 entries，不會覆寫或第二次讀取 project 檔案，確認內容穩定後再重跑。 |
| 專案命令連帶影響 Maven、Gradle 或其他 SDK | 回到 Java-only 分支；只在明確要求完整環境時使用專用 runner。 |
