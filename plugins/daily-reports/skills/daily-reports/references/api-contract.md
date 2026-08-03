# Daily Reports Personal API 合約

## 原始碼核對

本文件與 bundled client 是 Plugin 執行時的契約。若 ERP 行為、欄位或錯誤訊息與文件不一致，維護 Skill 時可查閱下列 checkout 的最新原始碼：

```text
/Users/samwang/code/github.com/softleader/softleader-erp
```

不要只因目錄存在就假設內容是最新版本。先保持工作樹不變並比對本機 `HEAD` 與遠端 `master`：

```bash
git -C /Users/samwang/code/github.com/softleader/softleader-erp rev-parse HEAD
git -C /Users/samwang/code/github.com/softleader/softleader-erp ls-remote origin refs/heads/master
```

兩者不同時，不要覆蓋或清除該 checkout 的未提交內容；先取得最新 ref，再以 `git show <resolved-ref>:<path>` 讀取：

```bash
git -C /Users/samwang/code/github.com/softleader/softleader-erp fetch origin master
git -C /Users/samwang/code/github.com/softleader/softleader-erp show FETCH_HEAD:<path>
```

優先核對：

- `src/main/java/tw/com/softleader/leave/apikey/web/ApiKeyChannelController.java`：Personal API routes、認證與參照選項驗證
- `src/main/java/tw/com/softleader/leave/apikey/web/ApiKeyChannelOpenApiModels.java`：OpenAPI schema、examples 與欄位說明
- `src/main/java/tw/com/softleader/leave/dailyreport/web/DailyReportReportingMain.java`：根層 request DTO
- `src/main/java/tw/com/softleader/leave/dailyreport/web/DailyReportReportingDetail.java`：detail DTO 與基本 validation
- `src/main/java/tw/com/softleader/leave/dailyreport/service/DailyReportService.java`：儲存規則、重複與工時檢核
- `src/test/java/tw/com/softleader/leave/dailyreport/web/ApiKeyChannelDailyReportControllerTest.java`：endpoint 行為與失敗案例

若最新原始碼與本文件不同，先更新本文件、client 與契約測試並完成驗證；不得在一次工作日誌提交中臨時猜測新欄位或未公開 endpoint。

## 連線

- 預設 base URL：`https://support.softleader.com.tw/backend/`
- 認證：`X-API-KEY` header
- Token 不支援 query string
- 使用者身分固定取自 API Key owner

## Endpoints

| Method | Path | 說明 |
| --- | --- | --- |
| GET | `/personal-api/probe` | 驗證 API Key |
| GET | `/personal-api/daily-reports/options/report-types` | 工作類型選項 |
| GET | `/personal-api/daily-reports/options/projects?reportDate=YYYY-MM-DD` | 指定日期可用專案 |
| GET | `/personal-api/daily-reports/options/projects/{projectId}/modules?reportDate=YYYY-MM-DD` | 指定日期與專案可用模組 |
| GET | `/personal-api/daily-reports/options/mandate-charters` | API Key owner 可用立案書 |
| POST | `/personal-api/daily-reports` | 新增或更新自己的工作日誌 |

目前沒有 Personal API 可查詢既有工作日誌。

## Submit payload

```json
{
  "reportDate": "2026-08-03",
  "details": [
    {
      "reportType": "PROJECT",
      "projectId": 701,
      "projectModuleId": 801,
      "hours": 2,
      "subject": "完成 Daily Reports Plugin",
      "description": "實作 API client 與安全確認流程",
      "todos": "補齊驗證"
    }
  ]
}
```

### 根層欄位

- `reportDate`：必填，`YYYY-MM-DD`
- `details`：必填，至少一筆

### Detail 欄位

- `id`：選填；有值代表更新既有明細，只能更新 owner 本人且日期符合的資料
- `reportType`：必填；目前為 `COMPANY`、`PROJECT`、`RD`、`OTHER`、`LEAVE`，仍以 options endpoint 為準
- `projectId`：`PROJECT` 必填，且須屬於 reportDate 當日可用專案
- `projectModuleId`：`PROJECT` 選填；若專案有模組且工時大於 0，後端要求選擇模組
- `mandateCharterId`：`RD` 選填，若有值須屬於 owner 可用立案書
- `modifiedTime`：更新輔助欄位，格式 `YYYY-MM-DDTHH:mm:ss`；不提供完整衝突控制保證
- `hours`：必填，0 到 9999，最多 2 位小數
- `subject`：必填，最多 100 字元
- `description`：選填，最多 900 字元；與 subject 合併後最多 1000 字元
- `todos`：選填，最多 900 字元

不屬於目前 `reportType` 的參照欄位應省略。

## 後端限制

- 每個 `PROJECT + module` 每日只允許一筆；應合併內容與工時。
- 每個 RD 立案書每日只允許一筆。
- 逾期回報時，部分組織規則要求工作日總工時至少 8 小時。
- 逾期修改可能保留原內容，將變更寫入修改後欄位。
- Personal API 無讀取既有日誌端點，因此 preflight 無法偵測與既有資料的重複項、既有明細 ID 或完整當日總工時。

## 回應

成功提交：

```json
{
  "reportDate": "2026-08-03",
  "detailCount": 1
}
```

常見失敗：

- `400`：payload 格式、欄位驗證或參照資料不合法
- `401`：Token 無效、停用或已 rotate
- `403`：缺少 `API_KEY_AUTHENTICATED`
