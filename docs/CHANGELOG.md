# Changelog

## [v3.2.0] - 2026-08-24

- 平台驗證由子字串比對改為等值比對，`TIGER_PLATFORM="amd nvidia"` 不再被放行。
- `00-pre-flight-advisor`：非互動環境下不再中止，改採預設 profile 並正常輸出調校檔。
- `00-pre-flight-advisor`：輸出的 key 更名為 `TIGER_OWUI_UVICORN_WORKERS`，OpenWebUI worker 建議值**首次生效**。
- `09-monitoring-alerting`：新增動作分派與 `uninstall`，`master-deploy.sh clean` 不再反而安裝並啟動監控。
- `05-rag-stack`：不再產生 host 端 `allow_anonymous true` 的 broker 設定檔（既有檔案不會被刪除）。
- `benchmark-tps.sh` 改用模組內 venv，不再對系統 Python 執行 `pip3 install`。
- 新增 `OLLAMA_CONTEXT_LENGTH=32768`；Redis 改用 `redis:8-alpine`；nvidia 的 docling 統一為 `cu130:v1.30.0`。
- Lemonade：`lemonade-edu` 與 `lemonade-rag` 的 context 設定對齊，`lemonade-embed` 的執行緒數改為推導。
- 非破壞性變更，`.env` 無需更名；Redis 與 docling 換 image 的注意事項見 Release Note。
- [Full Release Note](v3.2.0/RELEASE-NOTE.md)

## [v3.1.0] - 2026-08-18

- n8n：`N8N_SECRET` 更名為 `N8N_ENCRYPTION_KEY`，compose 端保留舊名 fallback 以免無聲換掉金鑰。
- n8n：以佔位值 `CHANGE_ME` 或未設定金鑰時，`deploy.sh` 拒絕啟動容器（`down` 不受影響）。
- 備份還原：解壓前先清空目標目錄，附五層防呆與 `--no-clean` 逃生口。
- 備份：`tar --sparse`，Qdrant 稀疏檔不再於還原時膨脹（實測 3.9 MB → 1.2 GB）。
- 健康檢查：`curl -sL` 跟隨轉址，Portainer 埠改讀 `PORTAINER_PORT`。
- 備份／還原／排程三支腳本補上執行權限。
- **破壞性變更**：`.env` 必須更名 n8n 金鑰，升級請見[遷移指南](MIGRATION.md)第 9、10 節。
- [Full Release Note](v3.1.0/RELEASE-NOTE.md)

## [v3.0.0] - 2026-08-13

- 三份平台 compose stack 合併為單一 `deployments/compose-stack/`，以 `TIGER_PLATFORM` 選擇平台。
- OpenWebUI 改為單一容器多 uvicorn worker，新增一次性 migration 服務。
- Lemonade 收斂為 AMD 專屬模組。
- MQTT broker 啟用認證。
- 修正多項因三份副本漂移而長期存在的監控與健康檢查缺陷。
- 新增 `lib/log.sh`：日誌與顏色收斂成單一來源，各腳本不再各自複製一份。
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

[v3.2.0]: https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v3.1.0...v3.2.0
[v3.1.0]: https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v3.0.0...v3.1.0
[v3.0.0]: https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v2.0.0...v3.0.0
[v2.0.0]: https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v1.3.0...v2.0.0
[v1.3.0]: https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v1.2.1...v1.3.0
[v1.2.1]: https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v1.2.0...v1.2.1
[v1.2.0]: https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v1.1.0...v1.2.0
[v1.1.0]: https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v1.0.0...v1.1.0
[v1.0.0]: https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/releases/tag/v1.0.0
