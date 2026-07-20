# 專案範圍 JDK 變更

只有在使用者明確要求持久化 `.sdkmanrc`，或套用其中完整 SDKMAN 環境時，才讀取本參考。

## 只執行專案指定的 Java

即使 `.sdkmanrc` 另含 `maven=`、`gradle=` 或其他 candidate，也將 Java-only 要求限制在 Java：

1. 從 `.sdkmanrc` 讀出完整 `java=` identifier。
2. 必要時用 `scripts/install-java.sh` 只安裝該 Java。
3. 回到 `SKILL.md` 步驟 5 的暫時分支；default 不存在時使用其中指向的 SDK home 分支。

此分支不執行 `sdk env install`，因為它會安裝並切換 `.sdkmanrc` 中的每一個 candidate。

**完成條件：**同一 shell 中的 `java -version`、`command -v java` 與實際命令都使用該完整 identifier。

## 將 identifier 持久化至 `.sdkmanrc`

只有在使用者要求專案層級持久化時才套用：

1. 記錄 `.sdkmanrc` 原先是否存在，並保存其完整原始內容。若既有檔案未受版本控制，使用 repo 外的唯一備份，且回報實際路徑：

   ```bash
   sdkman_switch_jdk_backup="$(mktemp "${TMPDIR:-/tmp}/sdkmanrc.XXXXXX")" && \
     cp .sdkmanrc "$sdkman_switch_jdk_backup" && \
     printf 'SDKMANRC backup: %s\n' "$sdkman_switch_jdk_backup"
   ```

2. 修改前計算有效的 `java=` 項目。沒有時新增 `java=<identifier>`；只有一個時更新該項並保留註解與其他 candidate。若超過一個，停止並列出衝突；只有在使用者明確要求修正重複項目時，才能更新第一項並移除其餘項目。
3. 修改後驗證恰好只有一個有效的 `java=` 項目，再檢查 diff，確認只包含預期的 Java 項目變更。
4. 必要時用 `scripts/install-java.sh` 安裝該 Java，再回到 `SKILL.md` 步驟 5 的暫時分支執行與驗證。

回復時，既有檔案應還原為保存的完整內容；若本次建立了新檔，先確認它仍是本次產物，再依使用者要求執行 `unlink .sdkmanrc`。不要使用會覆寫既有內容的固定 `.sdkmanrc.bak`。

**完成條件：**`.sdkmanrc` 恰好只有一個有效的 `java=` 項目、diff 只包含預期 Java 項目、實際命令成功，且回復方式能精確還原變更前狀態。

## 套用完整 SDKMAN 環境

只有在使用者明確要求 `.sdkmanrc` 的每個 candidate 時，才使用 `sdk env install`。先通過 `SKILL.md` 步驟 1 的重複 `java=` gate；有衝突時不得進入本分支。

必須從包含 `.sdkmanrc` 的目錄執行專用 runner。不要自行 source SDKMAN 後直接執行 `sdk env install`，因為該 inline 流程無法在 payload 前逐 candidate 驗證與還原 default。

runner 會先解析 `.sdkmanrc`、在共用跨程序 lock 內記錄每個 candidate 的 raw `current` symlink，再執行 `sdk env install`。未獲准的變更只有在 current 仍精確等於該 candidate 的 `.sdkmanrc` version 時才會原子還原；若有第三方漂移、比較失敗、還原失敗或 lock ownership 改變，runner 會保留較新的狀態並禁止 payload。

SDKMAN 可能為原本沒有 `current` 的 candidate 建立第一個 default。逐項說明這些 candidate，並只在使用者明確同意保留該 candidate 的 `.sdkmanrc` version 時加入對應授權：

```bash
bash <skill-dir>/scripts/run-sdkman-env.sh \
  [--allow-default <candidate>]... \
  -- <actual-command> [args...]
```

`--allow-default` 只適用於執行前為 `absent`、且存在於 `.sdkmanrc` 的 candidate；它只允許保留 `.sdkmanrc` 指定的 exact raw version target。它不允許改寫既有 default，也不接受重複或未列於 `.sdkmanrc` 的 candidate。沒有任何建立 default 的授權時，省略所有 `--allow-default`，runner 會還原每一個新建的 default。

需要 compound command 時，將 `bash -lc 'mvn test && mvn package'` 當成 `<actual-command> [args...]` 傳入；不要把命令文字插入 `bash -c` 程式本文。

runner 只在所有 candidate 的比較、還原、最終驗證與 lock release 都成功後才以 `exec` 執行 payload。SDKMAN 失敗且安全 reconciliation 成功時，保留 SDKMAN 的原始非零 status；CLI 或 `.sdkmanrc` 格式錯誤回傳 `2`，其他安全拒絕回傳 `1`。

**完成條件：**回報 SDKMAN 安裝或切換的每個 candidate、明確授權的新 default、實際命令結果，且所有未獲准變更的 default symlink 與執行前逐 byte 相同。
