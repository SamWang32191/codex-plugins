---
name: daily-reports
description: Safely draft, validate, preview, and submit the API key owner's SoftLeader ERP work report through `/personal-api/daily-reports`. Use when the user mentions 工作日誌、工作回報、daily report、daily-reports、回報工時、查詢可用工作類型／專案／模組／立案書，或要求新增或更新自己的工作日誌。
---

# Daily Reports

透過 bundled client 操作獨立的 Daily Reports Personal API。先查選項並預覽；只有使用者確認完全相同的 payload 後才提交。

## 安全界線

- API Token 只放在 `~/.config/softleader/agent-skills/daily-reports/config.json`，不得要求貼到對話或放在 query string。
- 查詢與預覽可直接執行；`submit` 會寫入 ERP，必須先展示完整 payload、日期、明細與總工時，再取得使用者明確確認。
- 使用 `preflight` 產生的確認碼提交；payload 變更後確認碼會失效，必須重新預覽與確認。
- 含 `id` 的明細代表更新。不得猜測 ID；提交更新還必須加 `--allow-updates`。
- 不得把「幫我寫／整理日誌」解讀為已授權送出。只有「送出／回報／提交」或對預覽內容的明確同意才是提交授權。

## 第一次使用

先執行：

```bash
python3 <skill-dir>/scripts/daily_reports.py precheck
```

若缺少設定，引導使用者在 ERP「API 金鑰管理」建立金鑰，並自行建立：

```json
{
  "apiToken": "<personal-api-token>"
}
```

不得代替使用者建立或複製真實 Token。設定完成後重新執行 `precheck`，必須 `ready=true` 才繼續。

## 工作流程

### 1. 取得合法選項

依需求執行：

```bash
python3 <skill-dir>/scripts/daily_reports.py options report-types
python3 <skill-dir>/scripts/daily_reports.py options projects --report-date YYYY-MM-DD
python3 <skill-dir>/scripts/daily_reports.py options modules --project-id ID --report-date YYYY-MM-DD
python3 <skill-dir>/scripts/daily_reports.py options mandate-charters
```

只使用 `options` 命令輸出的 ID，不依名稱猜測。查詢專案或模組時，必須帶實際 `reportDate`；client 會從 Personal API 取得該日期與 API key owner 可用的選項。

### 2. 整理 payload

將 payload 存在工作區暫存 JSON，不要放進 Plugin 目錄。欄位與型別規則見 [api-contract.md](references/api-contract.md)。使用者資料不足時先補問日期、每項工時、工作類型、主旨，以及 PROJECT/RD 必要的參照選項。

### 3. 預檢並展示

```bash
python3 <skill-dir>/scripts/daily_reports.py preflight --input <payload.json>
```

向使用者展示未省略的 payload、總工時、建立／更新筆數、warnings 與 `confirmationCode`。此步只會執行 GET，不會送出工作日誌。

### 4. 明確確認後提交

只有使用者確認步驟 3 的同一份內容後才執行：

```bash
python3 <skill-dir>/scripts/daily_reports.py submit \
  --input <payload.json> \
  --confirm <confirmationCode>
```

若 payload 含既有明細 `id`，還要加：

```bash
--allow-updates
```

回報 HTTP 結果、`reportDate` 與 `detailCount`。遇到 400/401/403 時保留 ERP 回應訊息，但不得輸出 Token。

## 唯讀要求

若使用者只要草稿、預覽、選項或檢查，停在 `preflight`；不得呼叫 `submit`。完整 endpoint 與已知限制見 [api-contract.md](references/api-contract.md)。
