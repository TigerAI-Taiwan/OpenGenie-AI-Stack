# OpenGenie AI Stack v2.0.0

本版聚焦 compose stack 的 database isolation、移除失效的 Node-RED 部署，以及備份／還原流程的多資料庫支援。n8n、OpenWebUI 與 Grafana 不再共用單一 database 或 SQLite state；既有環境可透過一次性 migration scripts 保留資料。另修正 NVIDIA／ARM64 DCGM Exporter 因 non-root 權限不足產生的重啟迴圈。

## What's Changed

- n8n、OpenWebUI、Grafana 改用各自獨立的 PostgreSQL database。
- 新增 n8n／OpenWebUI database migration scripts。
- 備份與還原改為動態處理多個 PostgreSQL databases。
- 完整移除 Node-RED 及相關 hooks。
- 修正 NVIDIA／ARM64 DCGM Exporter 權限。
- [PR #13：remove node red and add db isolate](https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/pull/13)

**Full Changelog**: [v1.3.0...v2.0.0](https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v1.3.0...v2.0.0)

## Release Details

### per-database isolation：n8n 與 OpenWebUI

舊版讓 n8n 與 OpenWebUI 共用 `tigerai` database，再以 `n8n`／`openwebui` schema 分隔。這會讓服務的 connection string、schema bootstrap 與 migration lifecycle 彼此耦合，也增加跨服務誤清 schema 的風險。

本版改為：

- n8n 使用專用 `n8n` database 與預設 `public` schema。
- OpenWebUI 使用專用 `openwebui` database，不再透過 connection string `search_path` 指向共用 schema。
- 各服務 deployer 將 `check_db_schema` 改為 idempotent `ensure_db`：先查詢 `pg_database`，不存在才執行 `CREATE DATABASE`。
- `02-database-postgres-pgadmin/deploy.sh` 移除過時的 `init_schemas()`，PostgreSQL bootstrap 只負責 database server 就緒。
- AMD、NVIDIA、ARM64 的 `.env.example` 與 compose connection strings 同步更新。

### 一次性 database migrations

三種 stack 根目錄新增：

- `migrations/n8n-db-rename-migration.sh`
- `migrations/openwebui-db-rename-migration.sh`

腳本會先檢查來源與目標、強制停止仍在寫入的 main／worker containers，並保存完整來源 database snapshot。接著建立專用 database，透過 `pg_dump`／`pg_restore` 複製指定 schema 的結構與資料，再於單一 transaction 內將複製的 schema promote 為 `public`。OpenWebUI 的 `alembic_version` 也會隨資料搬移，避免服務將目標誤判為全新 database。

腳本在目標 `public` schema 存在無關 tables 時會拒絕覆蓋；成功後也保留原本 `tigerai` 中的來源 schema，待操作者從 UI 驗證資料後再自行清除，提供明確 rollback 路徑。重複執行時會依目前狀態安全跳過或報告衝突。

全新安裝不需要 migration，deployer 會直接建立空的專用 database。既有安裝必須先遷移，再由新版 deployer 接手。

### 動態多資料庫備份

舊版只匯出單一 PostgreSQL database，無法涵蓋隔離後的 n8n、OpenWebUI 與 Grafana。本版會動態列舉所有非 template databases，逐一產生壓縮 dump。

- PostgreSQL container 名稱可由 `PG_CONTAINER` 設定。
- database 未執行時會標示備份不完整，不再靜默略過。
- bind-mount data paths 寫入 `data-paths.manifest`，讓 restore 知道原始位置。
- 自訂 `DATA_DIRS` 可加入額外需要封存的資料目錄。

### 多資料庫還原與 legacy 相容

- 新格式逐庫 drop／recreate／import。
- 支援舊版單一 `database.sql.gz` 備份，避免現有備份立即失效。
- 依 manifest 還原資料目錄，降低 basename 相同或執行目錄不同造成的錯置。
- destructive restore 前保留確認步驟，避免誤覆蓋執行中的環境。

### Grafana PostgreSQL backend

Grafana 原本使用 container volume 中的 SQLite。新版 deployer 以 SELECT guard 建立專用 `grafana` database，compose 透過 `GF_DATABASE_*` 連線至 PostgreSQL；`GF_DB_NAME` 加入 environment example。

由 provisioning 管理的 dashboards 與 datasources 會在啟動時重建。透過 UI 手動建立且只存在 SQLite 的內容不會自動遷移，升級前應自行 Export JSON。

### 移除 Node-RED

Node-RED 原生 installer 與 README 已移除，health check、monitor、backup、restore 與 master deploy usage 中的 Node-RED hooks 也同步清除。AMD stack 中未接入主流程的殘留 installer 一併刪除。

本版不會自動 uninstall 主機上既有的 `nodered.service`；若舊環境仍保留服務，需由操作者確認資料後自行停用或移除。

### DCGM Exporter non-root restart loop

DCGM Exporter 4.x image 預設以 non-root 使用者執行，但內建 `nv-hostengine` 需要較高權限才能讀取與監看 GPU fields，否則會出現 `Host engine is running as non-root` 並反覆重啟。

NVIDIA 與 ARM64 compose 的 `gpu-exporter` 現在加入：

- `user: root`
- `cap_add: SYS_ADMIN`

AMD 使用不同的 ROCm exporter，未套用此修改。

## Breaking Changes

- Node-RED 不再由 OpenGenie 部署、檢查、監控或備份。
- n8n database 從 `tigerai/n8n schema` 改為 `n8n/public`。
- OpenWebUI database 從 `tigerai/openwebui schema` 改為獨立 `openwebui` database。
- Grafana state backend 從 SQLite 改為 PostgreSQL。
- 未執行 migration 就直接部署新版，可能得到空 database，舊資料仍留在原位置。

## 部署注意事項

既有環境建議依序執行：

1. 停止會持續寫入 n8n、OpenWebUI、Grafana 的操作。
2. 使用舊版或已驗證的流程完成一次完整備份，並確認 dump 可讀。
3. 執行對應 stack 的 n8n 與 OpenWebUI migration scripts。
4. 更新 `.env` 中的 `DB_POSTGRESDB_DATABASE`、`DB_POSTGRESDB_SCHEMA`、`OWUI_DB_NAME` 與 `GF_DB_NAME`。
5. 重新部署 PostgreSQL、n8n、OpenWebUI 與 Grafana。
6. 使用新版 backup script 建立多資料庫備份，確認每個專用 database 都有 dump。

## 驗證重點

- PostgreSQL 應存在 `n8n`、`openwebui`、`grafana` databases，owner 與 connection credentials 正確。
- n8n workflows、credentials 與 executions 應保留，main／worker 能正常處理 queue jobs。
- OpenWebUI users、settings 與 histories 應可讀取。
- Grafana provisioned dashboards／datasources 應載入；需要保留的 UI dashboards 應完成手動匯入。
- NVIDIA／ARM64 `gpu-exporter` 應停止 restart loop，Prometheus 能讀取 DCGM metrics。
- 新版備份目錄應包含多個 database dumps 與 data path manifest。

## 已知限制

- Grafana SQLite → PostgreSQL 沒有自動資料搬移；UI-only state 需要人工 export／import。
- migration scripts 處理本 PR 定義的 n8n／OpenWebUI 轉換，不應拿來改名任意 database。
- Node-RED 舊資料與 systemd service 不會被自動刪除，避免發版過程破壞操作者尚未備份的 flows。
