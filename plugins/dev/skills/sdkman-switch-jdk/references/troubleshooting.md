# SDKMAN JDK 疑難排解

只有在核心安裝或 runner 流程失敗時，才讀取本參考。

## 驗證目前生效的 Java

以 `java -version` 與 `command -v java` 作為可觀察的真相。SDKMAN 5.20.0 在暫時 `sdk use` 後，`sdk current java` 仍可能回報 default；不要用它驗證目前 shell。

SDKMAN 輸出可能包含 ANSI escape。將 `sdk list java` 當作顯示資料，不要解析它來推論生效版本。

## 維持 default 不變

`scripts/install-java.sh` 會預先設定 `USE=n` 並對提示送入 `n`；`scripts/run-java.sh` 則在所有情況下將精確 candidate 的 `bin` 放到 `PATH` 最前方，且不會在缺少 Java default 時建立它。兩者都會比較執行前後的 `java/current`。`scripts/run-sdkman-env.sh` 會對 `.sdkmanrc` 的每個 candidate 執行相同的 raw-state 保護。

三個 runner 共用 `${SDKMAN_CANDIDATES_DIR}/.sdkman-switch-jdk.lock`，讓 snapshot、SDKMAN 操作與 reconciliation 不會彼此交錯。live owner 會使新呼叫 fail fast；metadata 完整、同一 EUID 且 PID 已不存在的 stale lock 會在重新核對後回收。metadata 不完整、ownership 不符或 PID 仍存活時一律保留 lock 並停止；先確認沒有相關 runner 後再人工檢查，不要直接遞迴刪除。

此 lock 是 bundled runner 間的合作式協調邊界。不要在 runner 執行期間以裸 `sdk default`、手動改寫 `current` 或其他不取得同一 lock 的流程並行變更 default；runner 會在每次還原寫入前重查漂移，但 portable Bash 無法把 state comparison 與 filesystem mutation 合併成單一 kernel operation。

runner 已同時設定 `JAVA_HOME` 與 `PATH`。若它回報 active Java 不符，檢查 `${SDKMAN_CANDIDATES_DIR}/java/<identifier>/bin/java` 是否存在且可執行。不要將 `JAVA_HOME` 指向 `java/current`；該 symlink 代表 default，不一定是要求的 identifier。

## 失敗處理

| 觀察 | 動作 |
| --- | --- |
| SDKMAN init script 不存在 | 停止並在安裝 SDKMAN 前取得同意。 |
| 沒有唯一 identifier 符合主版本 | 列出候選並要求選定 distribution；不要取清單第一筆。 |
| `Stop! <id> is not available.` | 重新查看 `sdk list java` 並選定完整可用 identifier。 |
| runner 回報 active Java 不符 | 檢查 candidate 的 `bin/java` 與 shell 執行環境；不要繞過 runner，修正原因後重跑。 |
| 專案命令連帶影響 Maven、Gradle 或其他 SDK | 回到 Java-only 分支；只在明確要求完整環境時使用 `sdk env install`。 |
