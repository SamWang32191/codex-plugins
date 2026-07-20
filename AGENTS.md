# AGENTS.md

## 適用範圍

本檔適用於整個 repository。修改時以最小正確範圍為原則，保留使用者或其他代理既有的未提交變更，不得重寫不屬於目前任務的檔案。

## Repository 模型

- `.agents/plugins/marketplace.json` 是 repo marketplace catalog。
- 每個 plugin 位於 `plugins/<name>/`，manifest 固定為 `plugins/<name>/.codex-plugin/plugin.json`。
- `VERSION` 是所有 plugins 的 canonical version。
- Manifest 的 `version` 是必要衍生值，所有 plugins 採 lockstep versioning。
- Local marketplace entry 不保存版本；不要在 `.agents/plugins/marketplace.json` 複製 manifest version。

## 版本規則

- 版本只接受 stable SemVer `X.Y.Z`，不接受 `v` 前綴、pre-release、build metadata 或數字段前導零。
- 不得單獨手改任何 manifest 的 `version`。
- 使用以下命令升級所有 plugins：

```bash
node scripts/bump-plugin-versions.mjs patch
node scripts/bump-plugin-versions.mjs minor
node scripts/bump-plugin-versions.mjs major
node scripts/bump-plugin-versions.mjs X.Y.Z
```

- 升版前若偵測到 manifest drift、無效 JSON 或無效版本，必須先解決並通過 `--check`；不得用升版命令覆蓋漂移。
- 保留升版腳本的 staged-write、backup 與 rollback 流程；不得改回直接以平行寫入覆蓋所有受管檔案。
- 若只修改文件或尚未準備發版，不要自行升版。

## 新增或修改 Plugin

- 新增 plugin 時，目錄名稱、manifest `name` 與 marketplace entry `name` 必須一致。
- 新 manifest 的 `version` 必須等於 `VERSION`，並由 `node scripts/bump-plugin-versions.mjs --check` 驗證。
- Marketplace local path 必須以 `./plugins/<name>` 表示，並保留 `policy.installation`、`policy.authentication` 與 `category`。
- 新增 plugin 時同步更新 `README.md` 的 Plugins 表格與相關測試；不要把 plugin 名稱硬編碼進升版腳本。
- 修改 manifest 的非版本欄位時，保留既有 metadata、assets 與使用者未提交的內容。

## 必要驗證

任何影響 plugin、manifest、marketplace 或版本工具的變更，都必須執行：

```bash
node --check scripts/bump-plugin-versions.mjs
node --test test/bump-plugin-versions.test.mjs
node scripts/bump-plugin-versions.mjs --check
```

新增或修改 JSON 後，確認 JSON 可以解析。CI 使用 Node.js 22 與 24 執行同一套 version-management tests 與 lockstep check。

## Codex Local Plugin 行為

- 修改 local plugin directory 後，重新啟動 ChatGPT desktop app 以載入已安裝的新 copy。
- `codex plugin marketplace upgrade` 只刷新 Git marketplace snapshots，不會修改 plugin manifest version，也不會重新載入 local plugin。

## 文件與交付

- Repository 文件使用繁體中文；程式識別字、路徑與 CLI 命令保留原文。
- 交付前檢查 `git diff` 與 `git status`，只報告本次實際修改；不得把共享 worktree 中的其他變更歸功於本次工作。
