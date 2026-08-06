# OpenGenie AI Stack v1.1.0

本版將 AMD、NVIDIA、ARM64 三套 compose stack 的健康檢查、n8n database 設定與 Qdrant 配置同步，讓 Docker 能以服務實際可用狀態判斷啟動結果，而不只依賴 container process 是否存在。

## What's Changed

- 為三種平台的核心服務加入 healthchecks。
- 同步 n8n schema、worker queue、URL 與 credential fallback。
- 依平台調整 Qdrant image、storage、GPU indexing 與 thread 數。
- NVIDIA／ARM64 Lemonade deployer 加入 AMD GPU guard。
- [PR #9：sync healthy check](https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/pull/9)

**Full Changelog**: [v1.0.0...v1.1.0](https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v1.0.0...v1.1.0)

## Release Details

### 跨 stack 健康檢查

三種 compose stack 為下列服務加入適合其 image 內建工具的 healthcheck：PostgreSQL、pgAdmin、Redis、Ollama、OpenWebUI main／worker、n8n main／worker、Mosquitto、Docling、Qdrant、Prometheus、Grafana、Loki、cAdvisor、node／GPU exporters 與 WUD。

檢查方式依 image 能力分別使用 `pg_isready`、HTTP ping、CLI、Python、`wget`、`curl` 或 bash TCP。Portainer CE／Edge Agent 採 scratch image，容器內沒有 shell 或 HTTP client，因此刻意不加入無法可靠執行的 healthcheck，改在 compose 註解中記錄外部監測方式。

### n8n database 與 queue mode

- `DB_POSTGRESDB_SCHEMA` 由 `public` 統一為 `n8n`。
- deployer 優先採用明確的 `DB_POSTGRESDB_*`，其次使用共用 `PG_*`，最後才使用 fallback。
- worker 啟用 queue health check，worker 數量採用 `TIGER_N8N_WORKERS → N8N_WORKERS → default`。
- `N8N_URL` 留空時由 deployer 在 network 準備完成後依 hostname 推導。
- restart action 改以重新部署處理 multi-worker topology，避免只 restart 現有 container 而漏掉 worker 數量變化。

### Qdrant 平台配置

- 新增 `QDRANT_MAX_THREADS`，取代固定的 search thread 數。
- storage 改用 `${BASE_DIR}/qdrant` bind mount，讓資料位置可由環境設定控制。
- AMD 預設使用 GPU image 並開啟 GPU indexing。
- ARM64 明確使用 CPU image，因當時沒有對應的 aarch64 Qdrant GPU image。
- NVIDIA／ARM64 既有 deploy resource override 保留，不被同步流程覆蓋。

### 環境設定同步

三種 `.env.example` 對齊 n8n database、Redis、Qdrant 與 base directory 的變數順序和說明。`N8N_URL` 與 `LEMONADE_API_KEY` 移除容易被誤用的硬編碼值，由操作者或 deployer 明確提供。

## 升級注意事項

- 升級後重新部署相關 compose projects，讓新增的 healthchecks 與 environment variables 生效。
- 既有 n8n database 若仍使用 `public` schema，切換至 `n8n` schema 前應確認資料位置；不要直接在有資料的環境盲目修改 schema。
- Qdrant storage 從 named volume 改為 bind mount 的平台，升級前應確認既有資料是否需要搬移。

## 驗證重點

- `docker compose ps` 應顯示支援的服務進入 `healthy`。
- 驗證 n8n main、worker 與 Redis queue 均正常，並執行一個測試 workflow。
- 檢查 Qdrant collections 與 storage path，確認升級後資料仍可讀取。
