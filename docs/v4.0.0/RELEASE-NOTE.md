# OpenGenie AI Stack v4.0.0

本版的主題是「不再帶著佔位值上線」：密碼、金鑰還是 `.env.example` 裡的 `CHANGE_ME` 時，
過去每個模組都照樣部署成功，而 compose 的 `${X:-CHANGE_ME}` fallback 讓這件事完全沒有症狀。
現在每個需要秘密的模組都有一支唯讀的 `pre-deploy.sh`，`master-deploy.sh` 會在部署任何東西之前
先檢查全部模組。同一批還有 Qdrant 開啟 API key、還原遇到 SQL 錯誤就中止，以及 n8n AI Assistant（預設關閉）。

**這是破壞性版本。** 既有機器升級後，`master-deploy.sh all` 很可能**整台被擋下**，
直到你補齊缺少的秘密為止；Qdrant 需要兩把新金鑰，而且有固定的升級順序。
請先讀完「升級注意」再動手。

## What's Changed

- 新增部署前秘密檢查：`02`／`03`／`04`／`05`／`10` 各一支唯讀 `pre-deploy.sh`，空值、全空白、精確的 `CHANGE_ME` 一律視為未設定。
- `master-deploy.sh all`／`app`／`restart` 先檢查全部模組，任何一項缺少就一個模組都不部署，並一次列出所有缺項；新增 `master-deploy.sh pre-deploy` 只做檢查。`down` 永遠不會被擋。
- `05-rag-stack`：Qdrant 開啟 API key（管理金鑰 `QDRANT_API_KEY`、唯讀金鑰 `QDRANT_READ_ONLY_API_KEY`），`03` 的 OpenWebUI 改帶管理金鑰。
- `08-backup-recovery`：還原的每個 `psql` 都加上 `ON_ERROR_STOP`，截斷或損壞的 dump 不再回報成還原成功。
- `04-automation-n8n`：新增 n8n AI Assistant（sandbox 加 SearXNG），主開關 `N8N_AI_ASSISTANT_ENABLED` 預設關閉。
- `04-automation-n8n`：移除 n8n 從來不讀的 `N8N_BLOCK_FS_WRITE_ACCESS` 與 `N8N_CORS_ALLOW_ORIGIN`；worker 加上預設註解掉的 Code node 自裝套件設定。
- `04-automation-n8n`：n8n 預設 image 改用 `stable` tag；`DB_POSTGRESDB_PASSWORD` 在 example 中改為註解（預設沿用 `PG_PASS`）。
- `06-ai-core-lemonade`（amd）：image 釘在 `v11.9.0` 並以 root 執行，修正全新部署時三個容器 CrashLoop；`GGML_VULKAN_DEVICE_*` 更名為 `GGML_VK_VISIBLE_DEVICES_*`。
- `07-validation-stack`：健康檢查加 5 秒逾時、埠改讀 `.env`、Lemonade 改打 `/live`；TPS benchmark 正確讀取改過的 Ollama 埠。
- `10-observability-grafana`：Prometheus／Alloy 設定變更後會重啟對應容器；移除空的 `docker-containers` job，nvidia／arm64 補上 `loki` job。
- 部署失敗時 ERR trap 改印「目錄/檔名 line N」。

## 升級注意

請照順序做。每一步都能在 `master-deploy.sh pre-deploy` 的輸出裡確認是否完成。

1. **先備份**（`08-backup-recovery`）。
2. **跑一次檢查，看哪些項目會擋下部署**：

   ```bash
   cd deployments/compose-stack
   ./master-deploy.sh pre-deploy
   ```

   每一個缺項都會印成一行 `[MISSING] <模組>/<變數> — …`，後面附處理方式。
3. **`PG_PASS` 不要直接改 `.env`。** 資料庫裡的密碼不會跟著 `.env` 變。請用 `[MISSING]` 訊息印出的單行指令：
   它先在資料庫執行 `ALTER USER`（SQL 走 stdin、`ON_ERROR_STOP`），成功後才寫進 `.env`。
   接著重新部署 `03`、`04`、`10`。
4. **`N8N_ENCRYPTION_KEY` 若一直以 `CHANGE_ME` 在跑，不要只改 `.env`。** n8n 2.x 無法原地換金鑰，
   換了會因為 `deployment_key` 解不開而拒絕啟動。唯一的路是新的空 n8n 資料庫搭配新金鑰，
   匯入事先匯出的 credentials 與 workflows。這是**有損遷移**（使用者、執行紀錄、變數等不會搬過去），
   需要人工規劃；判斷方式與注意事項見[遷移指南](../MIGRATION.md)第 9 節。
5. **`.env` 若仍有 `DB_POSTGRESDB_PASSWORD='CHANGE_ME'`，刪掉那一行**，讓它沿用 `PG_PASS`。
6. **Qdrant 兩把金鑰**，各自產生、必須相異：

   ```bash
   openssl rand -hex 32   # QDRANT_API_KEY
   openssl rand -hex 32   # QDRANT_READ_ONLY_API_KEY
   ```

   - **先部署 `03`，再部署 `05`。** 反過來的話，OpenWebUI 的 RAG 會安靜地回 401。
   - `05` 重建後，到 n8n UI 把 Qdrant credential 補上管理金鑰，否則用到 Qdrant 的 workflow 會 401。
   - 外部腳本直接打 Qdrant 的，要帶 `api-key` header。
   - 金鑰用上之後**不要再換**：OpenWebUI 與 n8n credential 裡的值會對不上，而且沒有任何症狀。
7. **amd：`GGML_VULKAN_DEVICE_*` 改名為 `GGML_VK_VISIBLE_DEVICES_*`。** 目前的 ggml 不讀舊名，沒有相容 fallback。
8. **可選**：`.env` 裡的 `N8N_CORS_ALLOW_ORIGIN=*` 可以刪掉；留著也無害。
9. 既有 `.env` 的 `N8N_IMAGE` 不會自動改成 `stable`，要換請自行修改。

行為變更（不需要動作，但要知道）：

- 沒有 `globals.sql.gz` 的舊備份，若 dump 引用了目標上不存在的 role，還原會在**該資料庫被 drop、重建之後**中止，
  後面的資料庫不會還原。原本只印出失敗的 `GRANT` 並繼續。

## Release Details

### 部署前秘密檢查：佔位值不再能上線

`.env.<platform>.example` 裡的秘密預設都是 `CHANGE_ME`，compose 端也用 `${X:-CHANGE_ME}` 當 fallback。
所以複製 example、忘了改就部署，每個服務都會正常啟動，用的是字面上的 `CHANGE_ME`：
PostgreSQL 密碼是它，n8n 用它加密每一筆 credential。沒有任何錯誤訊息。

本版在 `02`／`03`／`04`／`05`／`10` 各加一支唯讀的 `pre-deploy.sh`。判斷規則與 compose 的 fallback 對齊：
空值、全空白、精確的 `CHANGE_ME` 都算未設定。退出碼 0 表示全部設好，1 表示有缺項，而且**每一個缺項都會列出來**，
不會修一個、跑一次、再發現下一個。

- `master-deploy.sh all`／`app`／`restart` 先跑完全部模組的檢查，有任何缺項就一個都不部署。
  `restart` 也不會先重啟前面的模組再停在中間。
- 各模組自己的 `deploy.sh` 只擋會啟動容器的動作；`down` 永遠不擋。
- `03`、`10` 單獨部署時也會檢查 `PG_PASS`，因為它們的 compose 檔會用到。
- `04` 原本的 `check_encryption_key` 移進 `pre-deploy.sh`，另外檢查 `DB_POSTGRESDB_PASSWORD`（未設時取 `PG_PASS`）。
  「n8n 是否曾經跑過」改從 migrations 表判斷，而不是看 config 或 credentials 是否存在。
- 共用的判斷函式是 `lib/common.sh` 的 `is_placeholder`。

### Qdrant：開啟 API key

Qdrant 原本不需要認證，同一個網路上的任何容器都能讀寫向量庫。現在要求一把管理金鑰與一把唯讀金鑰，
`05/pre-deploy.sh` 檢查兩把都不是佔位值，兩把同值時只警告。OpenWebUI（`03`）改帶管理金鑰，
`03/deploy.sh` 另有一道縱深守衛。

升級順序之所以固定是「先 03 後 05」：`05` 一旦開啟認證，還沒帶金鑰的 OpenWebUI 打 Qdrant 就會 401，
而 OpenWebUI 的 RAG 不會把這個錯誤明顯地呈現出來。

### 還原：遇到第一個 SQL 錯誤就中止

`restore-tigerai.sh` 的 `psql` 原本沒有 `ON_ERROR_STOP`，每一句各自 commit。截斷或損壞的 dump
會在中途出錯、繼續往下跑，最後回報「還原成功」，實際上套用到哪裡無從得知。

現在每個還原 `psql` 都帶 `-v ON_ERROR_STOP=1`，第一個錯誤就中止並印出中止報告。
globals 有一個例外要處理：`pg_dumpall` 會重複輸出已存在 role 的 `CREATE ROLE x;`。
這些句子先改寫成冪等的 `DO … EXCEPTION WHEN duplicate_object`，其餘錯誤照樣中止。

### n8n AI Assistant（預設關閉）

`04-automation-n8n` 新增 n8n 的 AI Assistant，包含 sandbox 與 SearXNG，兩者放在 compose profile 後面。
主開關 `N8N_AI_ASSISTANT_ENABLED` 預設 `false`，既有機器不會多出任何容器。

- 開啟時，`SANDBOX_API_KEYS`／`SANDBOX_REGISTRATION_TOKEN`／`SANDBOX_RUNNER_API_KEY`／`SEARXNG_SECRET`
  由 `04/pre-deploy.sh` 檢查。
- `.env` 或 shell 環境設了 `COMPOSE_PROFILES` 都會被擋下，請改用主開關。
- `04` 的 `down`、`restart` 改用 `--profile '*'`，才收得掉 profile 內的容器。
- 主開關改回 `false` 後再部署（`all`／`main`／`worker`／`restart`），會停止並移除 sandbox 與 SearXNG 容器。
  無法辨識的值（例如打錯字）會警告並當成關閉。

⚠️ 這個功能在 n8n 官方標示為 Preview。sandbox 執行的是 LLM 生成的程式碼，而 runner 是 privileged DinD，
等同 host root。n8n 官方說內建的 `n8n-sandbox` 最適合本機開發與測試，正式環境建議用 Daytona。
開啟前請讀「已知限制」。

### n8n：移除兩個無效變數，worker 加上自裝套件設定

`N8N_BLOCK_FS_WRITE_ACCESS` 與 `N8N_CORS_ALLOW_ORIGIN` 不存在於 n8n：官方 env 文件沒有，原始碼也沒有
（查過 `n8n@2.40.5`，以及 0.150 到 1.100 的 config）。實測目前 `stable`（2.44.6）映像，同樣找不到這兩個名稱。
設了沒有作用，只會誤導讀者：一個不存在的「CORS `*`」，一個不存在的「寫入權限」開關。移除後執行期行為不變。

- 檔案存取真正的控制變數是 `N8N_BLOCK_FILE_ACCESS_TO_N8N_FILES` 與 `N8N_RESTRICT_FILE_ACCESS_TO`，維持原樣。
- REST API 的 CORS middleware 只在開發模式掛載，映像以 `NODE_ENV=production` 執行。
  Webhook 的 CORS 是 Webhook 節點自己的 *Allowed Origins* 選項。

n8n-worker 另外加上兩行預設註解掉的設定，讓 Code node 能 `require` 自己安裝的套件（例如 `httpntlm`、`xml2js`）：

```yaml
# - NODE_PATH=/home/node/.n8n/nodes/node_modules
# - NODE_FUNCTION_ALLOW_EXTERNAL=*
```

只放在 worker：queue mode 加上 `OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true` 時，Code node 只在 worker 的
task runner 裡執行。套件路徑在 `${N8N_DIR}` 底下，main 與 worker 都掛載同一個目錄。

- 啟用方式：去掉兩行的 `# `，執行 `./deploy.sh worker`。
- ⚠️ `=*` **不可加引號**。compose 的 list 形式會保留引號，`="*"` 送進去的是三個字元的 `"*"`，
  n8n 會把它當成套件名稱，結果全部擋掉。
- 啟用 `NODE_PATH` 會取代映像預設的 `/usr/local/lib/node_modules`（`npm -g` 裝的套件）。
- 用 `*` 時套件不會在凍結 prototype 前預載；若某個套件載入時報錯，改列名稱（`httpntlm,xml2js`）。

### Lemonade（amd）：全新部署 CrashLoop

Lemonade v11 以 uid 10001 執行，而全新部署建立的 `lemonade-*-cache` named volume 掛載點屬於 root，
`config.json` 寫不進去，三個容器反覆重啟。image 改釘 `v11.9.0`，以 `user: "0:0"` 執行，
並明確傳入 `config_dir`。

`GGML_VULKAN_DEVICE_*` 同時更名為 `GGML_VK_VISIBLE_DEVICES_*`：目前的 ggml 不讀舊名，設了沒有作用。
沒有相容 fallback，既有 `.env` 要自己改名。

### PostgreSQL 密碼：先改資料庫，再改 `.env`

`PG_PASS` 被擋下時，`02` 印出的單行指令會先在資料庫 `ALTER USER`（SQL 走 stdin、`ON_ERROR_STOP`），
成功才寫進 `.env`。`PG_USER`、`PG_CONTAINER` 或路徑不在白名單內時，退回印出手動步驟，不會產生可能出錯的指令。

### 健康檢查、benchmark 與觀測

- `07` 健康檢查：`curl` 加 `--max-time 5`；Ollama／OpenWebUI／n8n／Qdrant／Docling 的埠改讀 `.env`；
  Lemonade 只打 `/live`，不再檢查由 tiger-mode 互斥待命的 rag／embed。
- TPS benchmark：舊版永遠讀不到改過的 Ollama 埠。現在由 `.env` 的 `OLLAMA_PORT` 解析後經 `OLLAMA_HOST` 傳入；
  沿用的 `OLLAMA_HOST` 會補上 `http://`，`0.0.0.0` 改打 `localhost`；查詢模型清單加 5 秒逾時。
- `10`：`prometheus.yml`／`alloy-config.alloy` 內容變更後，`deploy.sh all` 會重啟對應容器。原本會沿用舊設定且不報錯。

## 未納入本版的上游項目

本版內容移植自 Open-AI-Stack 的三份變更紀錄，以下項目刻意不搬：

- `98` 模組、`secrets-adopt.sh`、拆分的 migration 目錄、`OLLAMA_IMAGE` digest 釘版。
- n8n env 那批的 K3s 部分（worker 的 hostPath `nodes/`），不屬於 compose。

上游最初的「Qdrant key 守衛」在第一批時未搬，第二批已一併移植，見上方 Qdrant 一節。

## 驗證

未於實體 GPU 硬體上驗證。以下為實際執行過的檢查：

- 7 個 compose 模組在 amd／nvidia／arm64 三平台，以各自的 `.env.<platform>.example` 跑
  `docker compose config`（含 `--profile '*'`），全數通過。
- repo 內 42 支 shell 腳本 `bash -n` 全數通過。
- n8n env 清理：改動前後的 `docker compose config` 在三平台都只差 n8n-main 的兩個 env；
  全 repo `git grep` 已無這兩個變數。把 worker 那兩行取消註解後，render 出未加引號的 `NODE_FUNCTION_ALLOW_EXTERNAL: '*'`。
  主機 `.env` 留著 `N8N_CORS_ALLOW_ORIGIN=*` 時 config 輸出與乾淨 env 相同。
- 以 `docker.n8n.io/n8nio/n8n:stable`（2.44.6）映像實測：`N8N_BLOCK_FS_WRITE_ACCESS`／`N8N_CORS_ALLOW_ORIGIN`
  兩個名稱零命中；REST CORS 只在 `inDevelopment` 時掛載。

## 已知限制

- **AI Assistant 的 runner 尚未隔離。** 它掛在共用的 `ai_stack_net`，開啟前請先實測 sandbox 內能不能連到
  同網路的其他服務（redis／ollama／docling）與 host。
- **關掉 AI Assistant 不會刪 volume。** volume 可能含有先前 sandbox 的資料，要完全清除須手動執行
  `docker volume rm 04-automation-n8n_sandbox-api-data 04-automation-n8n_sandbox-runner-1-docker`
  （前綴是 compose project name，預設為模組目錄名 `04-automation-n8n`）。
- **sandbox 的 mTLS 憑證含 CA 私鑰。** 放在 `SANDBOX_TLS_DIR`，預設位於 `BASE_DIR` 底下，會被 `08` 的備份打包，
  備份檔的保管等級須等同私鑰。
- **n8n 以 `CHANGE_ME` 跑過的機器沒有無損升級路徑**，見「升級注意」第 4 步。
  以 `--decrypted` 匯出的明文檔要放在 n8n 資料目錄以外、只有 root 能讀的目錄，用完即刪
  （資料目錄是 775、workflow 讀得到、`08` 備份也會打包）。
- **Qdrant 金鑰不支援輪替。** 換金鑰需要同時更新 OpenWebUI 與 n8n credential，對不上時不會有任何症狀。
- **[遷移指南](../MIGRATION.md) 尚未涵蓋 v4.0.0**，它目前寫的是 v2.0.0 → v3.1.0。本版的升級步驟以本文「升級注意」為準。
