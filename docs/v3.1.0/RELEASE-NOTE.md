# OpenGenie AI Stack v3.1.0

本版聚焦在「安靜壞掉」的三個地方：n8n 的加密金鑰可能在無任何徵兆下被換掉、
還原後的資料目錄可能既不是備份也不是現況、以及 Qdrant 的稀疏檔在還原時膨脹數百倍。
三者的共通點都是**不會報錯**，因此都改成在事前擋下或在事前修正。

**這是破壞性版本。** n8n 的 `N8N_SECRET` 已更名為 `N8N_ENCRYPTION_KEY`，
`04-automation-n8n/deploy.sh` 在 `.env` 未更名前**拒絕啟動任何容器**。
既有環境請先閱讀[遷移指南](../MIGRATION.md)第 9、10 節。

## What's Changed

- n8n：`N8N_SECRET` 更名為 `N8N_ENCRYPTION_KEY`，且以佔位值 `CHANGE_ME` 部署會被拒絕。
- 備份還原：解壓前先清空目標目錄，附五層防呆與 `--no-clean` 逃生口。
- 備份：`tar --sparse`，Qdrant 的稀疏 segment 檔不再於還原時膨脹。
- 健康檢查：`curl -sL` 跟隨轉址，Portainer 埠改讀 `PORTAINER_PORT`。
- `backup-tigerai.sh` / `restore-tigerai.sh` / `setup-cron.sh` 補上執行權限。
- `docs/MIGRATION.md` 新增第 9、10 節與一份強制性的 `.env` 必改清單。

## Release Details

### n8n 加密金鑰：更名，並拒絕以佔位值部署

`N8N_ENCRYPTION_KEY` 是 n8n 自己的變數名，舊有的 `N8N_SECRET` 只是多一層轉譯。
但**單純改名會無聲毀資料**：`.env` 不在版控內，改 `.env.example` 動不到現場機器，
若 compose 直接寫成 `${N8N_ENCRYPTION_KEY:-<預設>}`，只設過舊名的機器會落到預設值
——加密金鑰被悄悄換掉，容器照常啟動，直到數天後某次解密既有 credential 才爆。

因此 compose 端採巢狀 fallback `${N8N_ENCRYPTION_KEY:-${N8N_SECRET:-CHANGE_ME}}`，
舊名保留為安全網；`deploy.sh` 端則只接受新名，強制 `.env` 完成更名。

另一個獨立問題是 `CHANGE_ME`：它是**非空字串**，`:-` 兩層都不會觸發，所以未編輯過的
`.env` 會讓 n8n 用字面上的 `CHANGE_ME` 加密每一筆 credential，且一樣毫無徵兆。
`deploy.sh` 現在會在 `all` / `main` / `worker` / `restart` 前擋下：

- **`down` 刻意不擋** —— 處於此狀態的主機仍必須停得掉。
- 檢查在 `prep_files` / `ensure_network` / `ensure_db` 之前，被擋下的執行不會建立任何目錄或動到資料庫。
- 錯誤訊息會指向 `${N8N_DIR}/config` 的 `encryptionKey` 並要求**沿用那一把**。
  少了這句，只被告知「請設定真正的金鑰」的操作者會自己生一把新的貼上去，
  把既有 credential 永久孤兒化。

### 還原：解壓前先清空目標目錄

`tar -xzf` 只合併、不刪除，因此備份之後才寫入的檔案會存活過還原，留下一個
**既不是備份、也不是現況**的目錄。對序列結構的資料而言這是損毀而非凌亂：
備份後新建的 Qdrant collection 與 segment 目錄會留在原地，而覆蓋上去的
`config.json` 對它們一無所知。

現在每個目標目錄會在解壓前被清空，並有五層防呆：

1. **先驗證 archive，再刪任何東西。** 不可讀、空的、含絕對路徑成員或 `..` 成員一律中止，
   訊息都明確寫著「尚未刪除任何東西」——在清空之後才發現 tarball 損毀是沒有救的。
2. 目標必須位於 `BASE_DIR` 之內、深度足夠、不在 never-clear 清單（`/`、`/home`、`/var/lib` …）上。
3. 字面路徑與 `realpath` 都要通過清單比對，且目標本身不得為 symlink。
4. `STACK_DIR` / `BACKUP_ROOT` / `RESTORE_DIR` 不得位於目標之內。
5. 任何一項不通過就**退化成舊的合併行為並發出警告**，而不是猜。

只刪內容、不刪目錄本身：掛載點的 owner 與 mode 對服務有意義，且 bind mount 仍指著它。
需要舊行為時用 `--no-clean`。

⚠️ 預設 `DATA_DIRS` 等於整個 `BASE_DIR`，因此預設還原會清空並重寫整個資料根目錄。
這之所以安全，**唯一的理由是備份端沒有任何 `--exclude`**。日後若在
`backup-tigerai.sh` 加上排除項，必須同時收緊 `can_clean_target`，否則還原會變成
「清掉了但還原不回來」。

### 備份：`tar --sparse`

Qdrant 的 segment 檔是稀疏檔。沒有 `--sparse` 時 tar 會把每個空洞讀成真實的零位元組，
實測 3.9 MB 的實際資料還原後佔用 1.2 GB。此旗標只作用於建立端——稀疏性是 archive 的
metadata，**既有的舊 archive 不論怎麼解壓都仍會膨脹**，已還原的檔案可用
`fallocate --dig-holes` 回收空間。

### 健康檢查

`check_endpoint` 改用 `curl -sL`：會轉址的端點回報最終狀態碼，呼叫端不必再寫
`"200|302"`。目前 11 個呼叫點的期望碼都含 `200`，因此此變更安全；日後新增呼叫點時，
期望碼若寫成單獨的 `"302"` 將永遠無法命中。Portainer 探測改讀 `${PORTAINER_PORT:-9000}`，
它是堆疊中最後一處寫死 9000 的地方。

## 驗證

未於實體 GPU 硬體上驗證，以下為本版新增邏輯的實測：

- 金鑰守衛 23 項斷言，驅動真實的 `deploy.sh` 與 `lib/common.sh`（含 `set -Eeo pipefail`
  與 ERR trap），僅替換 `docker` 與 `sudo`。涵蓋金鑰解析的各種組合、四個 action 的分派、
  `down` 仍可執行、被擋下時未建立目錄、以及錯誤訊息必須指向既有金鑰。
- 還原防呆 26 項斷言（`debian:12`，macOS `realpath` 無 `-e`），含 symlink 逃逸與
  前綴陷阱（`/home/wrt/TigerAIX`、`/var/library`、`/var/lib2`、`/usr/locale`）。
  端到端以**集合相等**驗證：清空還原後只剩備份內的檔案，`--no-clean` 則兩者皆存，
  損毀的 tarball 回傳 rc=1 且兩個檔案都還在。
- n8n 巢狀 fallback 以 `docker compose config`（Compose v5.1.4）驗證四種 `.env` 情境，
  main 與 worker 三行結果一致。
- `tar --sparse`：160 MB apparent / 0 actual 的來源，未加旗標還原後實佔 160 MB，加了為 0。

## 已知限制

- **Docker named volume 完全不在備份範圍內** —— `pgdata`、`grafana_data`、
  `openwebui_data`、`pgadmin_data`、`portainer_data`、`alloy_data` 皆未涵蓋，
  備份只包含 `BASE_DIR` 底下的 bind mount。`pgdata` 由 `pg_dump` 間接涵蓋，
  但 Grafana dashboard 與 OpenWebUI 上傳檔案沒有其他來源。本版未處理。
- **`CHANGE_ME` 的守衛目前只有 n8n 一處。** `GRAFANA_PASS` 與 `MQTT_PASSWORD`
  仍會以佔位密碼把服務啟動起來；`PG_PASS` 系列的失敗模式較溫和（連線當場失敗）。
  尚未抽成共用的檢查。
