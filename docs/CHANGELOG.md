# Changelog

## [v3.0.0] - 2026-08-13

- 三份平台 compose stack 合併為單一 `deployments/compose-stack/`，以 `TIGER_PLATFORM` 選擇平台。
- OpenWebUI 改為單一容器多 uvicorn worker，新增一次性 migration 服務。
- Lemonade 收斂為 AMD 專屬模組。
- MQTT broker 啟用認證。
- 修正多項因三份副本漂移而長期存在的監控與健康檢查缺陷。
- **破壞性變更**，升級請見 [遷移指南](MIGRATION.md)。
- [Full Release Note](v3.0.0/RELEASE-NOTE.md)

## [v2.0.0] - 2026-08-05

- 移除 Node-RED 及相關的部署、監控與備份流程。
- 將 n8n、OpenWebUI 與 Grafana 移至各自獨立的 PostgreSQL database。
- 新增資料庫 migration 與多資料庫備份／還原功能。
- 修正 NVIDIA／ARM64 DCGM Exporter 權限問題。
- [Full Release Note](v2.0.0/RELEASE-NOTE.md)

## [v1.3.0] - 2026-07-26

- 新增 n8n Prometheus metrics 與 Grafana dashboard。
- 新增 Grafana Alloy，將容器 stdout／stderr 傳送至 Loki。
- 強化 PostgreSQL schema 初始化與 n8n 安全設定。
- [Full Release Note](v1.3.0/RELEASE-NOTE.md)

## [v1.2.1] - 2026-06-28

- 修正 NVIDIA 與 ARM64 Lemonade deployer 的 AMD GPU guard。
- [Full Release Note](v1.2.1/RELEASE-NOTE.md)

## [v1.2.0] - 2026-06-28

- 導入 self-guarding init 與一致的安裝／重開機流程。
- 將三種平台的 pre-flight advisor 統一更名為 `deploy.sh`。
- 更新部署文件、tuning file 路徑與環境設定範例。
- [Full Release Note](v1.2.0/RELEASE-NOTE.md)

## [v1.1.0] - 2026-06-28

- 為 AMD、NVIDIA 與 ARM64 compose stacks 的核心服務加入健康檢查。
- 同步 n8n、Qdrant、Lemonade 與環境設定行為。
- [Full Release Note](v1.1.0/RELEASE-NOTE.md)

## [v1.0.0] - 2026-06-12

- 支援 NVIDIA 多 GPU VRAM 加總。
- NVIDIA 與 ARM64 部署會自動略過 AMD 專用的 Lemonade module。
- 更新部署、錯誤復原與完整清除指引。
- [Full Release Note](v1.0.0/RELEASE-NOTE.md)

[v3.0.0]: https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v2.0.0...v3.0.0
[v2.0.0]: https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v1.3.0...v2.0.0
[v1.3.0]: https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v1.2.1...v1.3.0
[v1.2.1]: https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v1.2.0...v1.2.1
[v1.2.0]: https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v1.1.0...v1.2.0
[v1.1.0]: https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v1.0.0...v1.1.0
[v1.0.0]: https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/releases/tag/v1.0.0
