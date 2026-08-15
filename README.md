# SamWang Codex & Antigravity Plugins

這個 repository 以單一架構管理多個 Codex 與 Antigravity 雙平台相容的 plugins，並使用 lockstep versioning 讓所有 plugin manifest 保持同一版本。

## Plugins

| Plugin | 路徑 | 用途 |
| --- | --- | --- |
| `cmd` | `plugins/cmd` | 提供 commit、push、建立 branch 與 PR 等明確呼叫的工作流程。 |
| `dev` | `plugins/dev` | 提供 SDKMAN/JDK 切換等開發工具。 |

- **Codex Marketplace** 定義位於 `.agents/plugins/marketplace.json`。它登記 plugin 名稱、來源路徑與安裝政策，不保存 local plugin 的版本。
- **Antigravity Workspace 註冊** 定義位於 `.agents/plugins.json`，宣告 workspace 根目錄下的 `plugins/`。

## Repository 結構

```text
.
├── .agents/
│   ├── plugins.json
│   └── plugins/marketplace.json
├── .github/workflows/plugin-versions.yml
├── plugins/
│   ├── cmd/
│   │   ├── .codex-plugin/plugin.json
│   │   └── plugin.json
│   └── dev/
│       ├── .codex-plugin/plugin.json
│       └── plugin.json
├── scripts/bump-plugin-versions.mjs
├── test/bump-plugin-versions.test.mjs
└── VERSION
```

`VERSION` 是 canonical version。每個 `plugins/*/.codex-plugin/plugin.json` 與 `plugins/*/plugin.json` 的 `version` 是由升版腳本同步的必要衍生值。

## 版本管理

需要 Node.js 26 以上版本；腳本只使用 Node.js 標準函式庫，不需要安裝套件。

查看與檢查目前版本：

```bash
cat VERSION
node scripts/bump-plugin-versions.mjs --check
```

一次更新所有 plugins：

```bash
node scripts/bump-plugin-versions.mjs patch  # 0.1.1 -> 0.1.2
node scripts/bump-plugin-versions.mjs minor  # 0.1.1 -> 0.2.0
node scripts/bump-plugin-versions.mjs major  # 0.1.1 -> 1.0.0
node scripts/bump-plugin-versions.mjs 1.0.0  # 指定版本
```

腳本會自動掃描所有 `plugins/*/.codex-plugin/plugin.json` 與 `plugins/*/plugin.json`，所以新增 plugin 後不需修改升版清單。它只接受 stable SemVer `X.Y.Z`；更新前會完整檢查 `VERSION`、JSON 與版本漂移，前置檢查失敗時不會寫入任何受管檔案。實際更新會先在各檔案所在目錄完成暫存與備份，再以 atomic rename 提交；一般 I/O 提交錯誤會嘗試回復原始內容。

請勿單獨手改 manifest 的 `version`。若版本已漂移，先修正原因並執行 `--check`，再進行下一次升版。

## 新增 Plugin

1. 建立 `plugins/<name>/.codex-plugin/plugin.json`（Codex manifest）與 `plugins/<name>/plugin.json`（Antigravity manifest），以及需要的 `skills/`、`rules/` 等內容。
2. 雙平台 Manifest 必須包含穩定的 kebab-case `name`、與 `VERSION` 相同的 `version`。
3. 在 `.agents/plugins/marketplace.json` 新增 local source entry，路徑使用相對於 repository root 的 `./plugins/<name>`。
4. 更新本 README 的 Plugins 表格。
5. 執行完整驗證：

```bash
node --check scripts/bump-plugin-versions.mjs
node --test test/bump-plugin-versions.test.mjs
node scripts/bump-plugin-versions.mjs --check
```

## Local Plugin 更新與載入

- **Codex (ChatGPT Desktop App)**：修改 local plugin directory 後，重新啟動 ChatGPT desktop app 以載入已安裝的新 copy。`codex plugin marketplace upgrade` 只會刷新已設定的 Git marketplace snapshots。
- **Antigravity**：透過 `.agents/plugins.json` 自動識別與載入 `plugins/` 目錄下的各個 plugin。

## CI

`.github/workflows/plugin-versions.yml` 會在最低支援版本 Node.js 26 上執行測試與 `--check`。任何 manifest 漂移、無效 JSON 或無效版本都會使 CI 失敗。
