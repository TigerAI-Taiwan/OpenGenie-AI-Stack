# Changelog

## [v2.0.0] - 2026-08-05

### Features

- 新增既有安裝環境使用的 n8n 與 OpenWebUI 資料庫遷移工具。
- 備份與還原流程支援多資料庫。

### Refactor

- 移除 Node-RED 及相關的健康檢查、監控與備份流程。
- 將 n8n、OpenWebUI 與 Grafana 改用獨立的 PostgreSQL 資料庫。

### Fixes

- 修正 NVIDIA 與 ARM64 的 DCGM Exporter 執行權限。

### Breaking Changes

- Node-RED 不再屬於部署內容。
- 資料庫配置及既有資料的遷移方式已變更，升級前應先備份。

### Pull Requests

- [#13](https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/pull/13) Feat/remove node red and add db isolate

## [v1.3.0] - 2026-07-26

### Features

- 新增 n8n Prometheus metrics、Grafana dashboard 與 stdout log 面板。
- 新增 Grafana Alloy，將容器 stdout/stderr 傳送至 Loki。
- 將 n8n stdout 改為 JSON 格式並解析 log level 與 timestamp。

### Fixes

- 強化 n8n 檔案存取限制、資料庫 schema 初始化及 Alloy timestamp 解析。

### Pull Requests

- [#12](https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/pull/12) Feat/n8n stdout log

## [v1.2.1] - 2026-06-28

### Fixes

- 修正 NVIDIA 與 ARM64 Lemonade 部署程式中的 AMD GPU 偵測 guard block。

### Pull Requests

- [#11](https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/pull/11) fix: update detect_amd_gpu guard block

## [v1.2.0] - 2026-06-28

### Refactor

- 將各平台的 pre-flight advisor 從 `tiger-advisor.sh` 統一更名為 `deploy.sh`。
- 整合初始化、GPU driver 偵測與 advisor 執行流程。
- 修正 NVIDIA 與 AMD tuning file 路徑以及 NVIDIA 環境設定範例。
- 同步更新安裝、部署狀態、錯誤復原及完整清除文件。

### Pull Requests

- [#10](https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/pull/10) Feat/consolidate files

## [v1.1.0] - 2026-06-28

### Features

- 為 AMD、NVIDIA 與 ARM64 compose stacks 的服務加入健康檢查。
- 同步三種平台的環境設定、部署程式與 compose 配置。

### Pull Requests

- [#9](https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/pull/9) feat: sync healthy check

## [v1.0.0] - 2026-06-12

### Features

- 整合多 GPU 判斷、安全清除及互動式 port conflict 處理。
- NVIDIA 與 ARM64 部署會自動略過 AMD 專用的 Lemonade module。
- 更新 deployment skills 與相關連結。

### Pull Requests

- [#8](https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/pull/8) 更新 skills、多顯卡判斷

[v2.0.0]: https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v1.3.0...v2.0.0
[v1.3.0]: https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v1.2.1...v1.3.0
[v1.2.1]: https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v1.2.0...v1.2.1
[v1.2.0]: https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v1.1.0...v1.2.0
[v1.1.0]: https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v1.0.0...v1.1.0
[v1.0.0]: https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/releases/tag/v1.0.0
