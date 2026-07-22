---
name: bump-new-version
description: 安全地升級此 repository 所有 Codex plugin 的 lockstep 版本。當使用者要求發布、升級 `VERSION`、同步所有 plugin manifest 的 version，或指定 patch、minor、major、stable SemVer 目標版本時使用；使用者未指定時預設升級 patch，僅修改文件或尚未準備發版時不要使用。
---

# Bump New Version

以 repository root 為工作目錄，並只使用既有的 `scripts/bump-plugin-versions.mjs` 升版。`VERSION` 是 canonical version；所有 `plugins/*/.codex-plugin/plugin.json` 的 `version` 必須與它一致。

## 決定目標版本

- 優先採用使用者明確指定的 `patch`、`minor`、`major` 或 `X.Y.Z`。
- 使用者未指定時，一律選擇 `patch`；不要依變更影響推論版本類型，也不要為此追問使用者。
- 只接受 stable SemVer `X.Y.Z`；拒絕 `v` 前綴、pre-release、build metadata 與數字段前導零。
- 不要因為只有文件變更或尚未準備發版而升版。

## 升版流程

1. 確認在 repository root，並檢查工作目錄：

   ```bash
   git rev-parse --show-toplevel
   node --version
   git status --short
   ```

   驗證應使用 Node.js 22 或 24。保留其他人既有的未提交變更；若 `VERSION` 或 plugin manifest 已有與本次升版無關的變更，先釐清其意圖。

2. 先執行完整前置檢查：

   ```bash
   node --check scripts/bump-plugin-versions.mjs
   node --test test/bump-plugin-versions.test.mjs
   node scripts/bump-plugin-versions.mjs --check
   ```

   `--check` 失敗代表 manifest drift、無效 JSON 或無效版本。先修正根因並重新通過檢查；不要以升版命令覆蓋漂移。

3. 只執行一個對應的升版命令。使用者未指定時，執行 `patch`：

   ```bash
   node scripts/bump-plugin-versions.mjs patch  # 未指定時的預設，或明確指定 patch
   node scripts/bump-plugin-versions.mjs minor
   node scripts/bump-plugin-versions.mjs major
   node scripts/bump-plugin-versions.mjs X.Y.Z
   ```

   不要手動改寫 `VERSION` 或任一 manifest 的 `version`。腳本會掃描所有 plugin manifest，採 staged write、backup 與 rollback 同步受管檔案。

4. 升版後重新執行必要驗證，並確認 diff 範圍：

   ```bash
   node --check scripts/bump-plugin-versions.mjs
   node --test test/bump-plugin-versions.test.mjs
   node scripts/bump-plugin-versions.mjs --check
   git diff --check
   git diff -- VERSION plugins
   git status --short
   ```

   預期只有 `VERSION` 與各 plugin manifest 的 `version` 被同步更新；保留 manifest 其餘 metadata。Marketplace catalog 不保存版本，因此不要在 `.agents/plugins/marketplace.json` 加入或修改版本。

## 交付界線

- 回報舊版與新版、實際執行的升版命令，以及每項驗證結果。
- 除非使用者明確要求，不要自行建立 commit、tag、push，或執行 `codex plugin marketplace upgrade`。
- 若使用者還需要已安裝的 local plugin 載入內容，提醒其重新啟動 ChatGPT desktop app；升版腳本本身不會重新載入 plugin。
