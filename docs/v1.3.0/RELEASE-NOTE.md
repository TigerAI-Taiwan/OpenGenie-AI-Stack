# OpenGenie AI Stack v1.3.0

本版補齊 n8n 的 metrics 與 log observability：Prometheus 收集 main／worker 指標、Grafana 提供專用 dashboard、Alloy 將 Docker stdout／stderr 傳送至 Loki。同時修正 PostgreSQL schema 初始化會隱藏錯誤的問題，並強化 n8n proxy 與檔案存取設定。

## What's Changed

- 新增 n8n Prometheus metrics、queue metrics 與 Grafana dashboard。
- 新增 Grafana Alloy，集中收集容器 stdout／stderr 至 Loki。
- n8n 改輸出 JSON logs，dashboard 可直接檢視 stdout。
- 強化 database schema initialization 與 n8n runtime settings。
- [PR #12：n8n stdout log](https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/pull/12)

**Full Changelog**: [v1.2.1...v1.3.0](https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v1.2.1...v1.3.0)

## Release Details

### n8n metrics 與 dashboard

三種 compose stack 的 n8n main／worker 啟用 `N8N_METRICS` 與 queue metrics。Prometheus 新增 n8n scrape job，Grafana provisioning 新增 n8n dashboard，涵蓋 execution 狀態、queue、process 與 worker 相關指標。

這些 metrics 使用 n8n 提供的 Prometheus endpoint，不依賴 Enterprise license。main 與 worker 都暴露 metrics，便於分辨入口服務與背景執行節點的狀態。

### Alloy 與 Loki log pipeline

- 新增 `alloy-config.alloy` 與 Alloy service。
- Alloy 透過 Docker socket discovery 收集所有 container stdout／stderr。
- logs 經 shared `ai_stack_net` 傳送至 Loki。
- n8n main／worker 設定 `N8N_LOG_FORMAT=json`，每行輸出一個 JSON object。
- Alloy 從 `metadata.timestamp` 取出正確時間，並只將低基數 level 提升為 label，其他欄位保留於 log body，避免 Loki series 爆增。
- n8n dashboard 新增 Loki log panel，無須切換至 Explore 即可查看 stdout。

### DCGM Exporter image

NVIDIA 與 ARM64 的 DCGM Exporter 改用 NVIDIA NGC `nvcr.io/nvidia/k8s/dcgm-exporter` multi-arch image，避免 Docker Hub rate limits 並統一實際使用的版本。AMD stack 繼續使用 ROCm exporter，不受此變更影響。

### PostgreSQL schema 初始化修正

舊流程以 `2>/dev/null || true` 忽略 schema 建立失敗，部署表面成功但 n8n／OpenWebUI 之後可能因 schema 不存在而啟動失敗。本版移除 error swallowing，讓 `psql` 錯誤直接使部署停止。

- NVIDIA／ARM64 補上 `PG_USER` 與 `PG_DB_NAME` fallback。
- AMD 的 `all`／`postgres` action 改為使用相同的 `wait_for_db + init_schemas` 路徑。
- 三種平台不再各自維護容易分歧的 inline schema initialization。

### n8n runtime 加固

- main 設定 `N8N_PROXY_HOPS=1`，配合反向代理取得正確來源資訊。
- main／worker 加入檔案存取控制變數，明確定義 n8n files 與允許路徑行為。
- environment examples 新增 metrics、JSON log 與 Alloy image 設定。

## 升級注意事項

- 重新部署 n8n、Prometheus、Grafana、Loki 與 Alloy，僅 restart 舊 container 不會建立新 service 或載入新 provisioning files。
- Alloy 需要唯讀存取 Docker socket；部署前應確認主機權限政策允許。
- schema 初始化現在會正確失敗；若升級時中止，應先處理 PostgreSQL credential、database 或權限問題，不要重新加入 `|| true`。

## 驗證重點

- Prometheus targets 中 n8n main／worker 應為 `UP`。
- Grafana 應自動載入 n8n dashboard，metrics panels 有資料。
- 執行測試 workflow 後，Loki panel 應可看到帶有正確 timestamp 與 level 的 JSON logs。
- Alloy、Loki 與 n8n containers 應保持 healthy，且 Alloy log 中無 Docker discovery 或 push errors。

## 已知限制

- Alloy 收集所有 Docker container logs，實際 retention 與磁碟用量仍取決於 Loki 設定。
- dashboard 顯示品質取決於 n8n 版本所提供的 metrics names；未來升級 n8n 時應重新驗證 queries。
