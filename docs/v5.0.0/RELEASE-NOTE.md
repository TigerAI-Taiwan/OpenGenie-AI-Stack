# OpenGenie AI Stack v5.0.0

本版的主題是「推論後端獨立成一層」：推論引擎從 OpenWebUI 模組拆出來，成為新的 Phase 03（`03-ai-core/<後端>`），
每台機器只部署一個後端，由 stack `.env` 的 `INFERENCE_BACKEND` 明確指定——nvidia／arm64 是 `ollama`，amd 是 `lemonade`。
後面的模組因此往後挪一號，Redis 搬到資料庫層，SearXNG 改為一律部署。

**這是破壞性版本。** 模組目錄改名會讓 compose project 名稱與 named volume 前綴跟著變，
既有機器**必須**先補上 `INFERENCE_BACKEND`、再跑一次性的 `migrations/renumber-migrate.sh`，才能部署新版；
**AMD 機器不再跑 Ollama**，OpenWebUI 的模型連線要手動改到 Lemonade。請先讀完「升級注意」再動手。

## What's Changed

- 模組重新編號：`03-ai-interface-ollama-openwebui-redis` → `04-ai-interface-openwebui`、`04-automation-n8n` → `05-automation-n8n`、`05-rag-stack-docling-qdrant-mosquitto` → `06-rag-stack-docling-qdrant-mosquitto`、`06-ai-core-lemonade` → `03-ai-core/lemonade`；Ollama 拆成新模組 `03-ai-core/ollama`。
- 新增 `INFERENCE_BACKEND`（**必填**）：nvidia／arm64 只接受 `ollama`，amd 只接受 `lemonade`；空值或其他值一律擋下，訊息會印出該平台要設的值。新增 `03-ai-core/pre-deploy.sh`，`master-deploy.sh pre-deploy` 會一起檢查。
- `lib/common.sh` 新增推論後端的 validate／resolve／cutover：部署 03 時先拉 image、再卸載本 stack 留下的另一個後端容器（模型與 volume 不刪），最後才 `up -d`；遇到非本 stack 建立的同名容器就整批不動。
- 新增 `migrations/renumber-migrate.sh`：預設只列出、`--apply` 才執行，可重跑；停掉舊 project、把 named volume 複製到新前綴、搬模組層 `.env`、把 `OLLAMA_*` 挪到 `03-ai-core/ollama/.env`、修正 RAG 的 `@reboot` cron。有任何 CONFLICT 時 `--apply` 一項都不做。
- Redis 從 OpenWebUI 模組搬到 `02-database-postgres-pgadmin`；`04` 部署前會等 redis healthy。
- `04-ai-interface-openwebui`：模型連線依 `INFERENCE_BACKEND` 疊 `docker-compose.backend-<後端>.yaml`（ollama → `http://ollama:11434`；lemonade → Lemonade EDU 的 OpenAI 相容 API）。三份平台 overlay 目前都是空的。
- **AMD 不再部署 Ollama**：AMD 的 Ollama（Vulkan）overlay 移除，AMD 的推論只剩 Lemonade。
- `05-automation-n8n`：SearXNG 一律部署（啟動失敗只警告、不擋 n8n），新增 `searxng` 動作可單獨重試；`N8N_AI_ASSISTANT_ENABLED` 預設改為 `true`，只控制 sandbox 與 n8n 是否接 SearXNG。`SEARXNG_SECRET` 每台都必填，sandbox 三把金鑰在開關為 true（含未設）時必填。
- `07-validation-stack`：健康檢查依 `INFERENCE_BACKEND` 決定檢查 Ollama API 還是 Lemonade；TPS benchmark 只支援 ollama，其他值直接說明並退出。
- `08-backup-recovery`：每日 VRAM purge 改為重啟「這台的推論後端」，後端在安裝 cron 時寫進 crontab 那一行；舊的 cron 行會被替換。
- `09-monitoring-alerting`：tiger-monitor 依部署時判定的後端探測 Ollama 或 Lemonade，後端寫進 systemd unit 的 `Environment=`；重新安裝會重啟 unit。
- **破壞性變更**：既有機器必須先補 `INFERENCE_BACKEND`、跑 `renumber-migrate.sh`，並重新安裝 08 的 cron 與 09 的 unit。

## 升級注意

請照順序做。

0. **在一切之前，先在 stack `.env` 加一行 `INFERENCE_BACKEND`。**
   `deployments/compose-stack/.env` 是 gitignored，新版的 `.env.<platform>.example` 不會自己出現在既有機器上，請手動加：

   | 平台 | 要加的那一行 |
   |---|---|
   | amd | `INFERENCE_BACKEND=lemonade` |
   | nvidia、arm64 | `INFERENCE_BACKEND=ollama` |

   - 單獨一行，**不要加行尾註解**（shell 的 `source` 與 compose 的 `--env-file` 對 `#` 的解讀不同）。
   - 沒加的話：`master-deploy.sh pre-deploy`、遷移腳本（CONFLICT，`--apply` 什麼都不做）、
     以及 03／04／08 的 `cron`·`purge`／09 的每一次部署都會停下，並印出該設的值；07 的健康檢查把後端列為 FAIL，benchmark 拒絕執行。
   - 同時補上 `SEARXNG_SECRET`（現在每台都必填），以及 sandbox 的三把金鑰
     `SANDBOX_API_KEYS`／`SANDBOX_REGISTRATION_TOKEN`／`SANDBOX_RUNNER_API_KEY`——
     或者不要 sandbox，就設 `N8N_AI_ASSISTANT_ENABLED=false`（預設已改為 `true`）。
     每一把都用 `openssl rand -hex 32` 各自產生；`master-deploy.sh pre-deploy` 會列出還缺哪些。
   - 既有 `.env` 若有 `OLLAMA_IMAGE`，它會蓋過 example 的值。**AMD 請把 `OLLAMA_IMAGE` 與其他 `OLLAMA_*` 行刪掉**，已經不會再被讀取。
1. **跑遷移腳本**（先列出、確認後再執行）：

   ```bash
   cd deployments/compose-stack
   sudo bash migrations/renumber-migrate.sh            # 只列出，不動任何東西
   sudo bash migrations/renumber-migrate.sh --apply    # 執行
   ```

   遷移腳本會自行偵測平台；偵測不到時會停下並要求加上 `TIGER_PLATFORM=`（例如 `sudo TIGER_PLATFORM=amd bash migrations/renumber-migrate.sh`）。

   **`--apply` 開始就是停機**：OpenWebUI、n8n、RAG 與舊的推論後端都會停下；**AMD 的 Ollama 容器會被永久移除**。
   有 CONFLICT 時 `--apply` 一項都不做，照訊息處理後重跑即可；腳本可重跑，做完的項目顯示 GONE／DONE。
2. **部署推論後端**（仍在 `deployments/compose-stack` 下執行）。直接呼叫模組的 `deploy.sh` 不會自動偵測平台，
   一定要帶 `TIGER_PLATFORM=<amd|nvidia|arm64>`，沒帶會直接報錯：

   ```bash
   cd deployments/compose-stack
   sudo -E TIGER_PLATFORM=nvidia bash 03-ai-core/ollama/deploy.sh all     # nvidia（arm64 換成 TIGER_PLATFORM=arm64）
   sudo -E TIGER_PLATFORM=amd bash 03-ai-core/lemonade/deploy.sh all      # amd
   ```

3. **在 `deployments/compose-stack` 下執行 `sudo -E bash master-deploy.sh all`**（`master-deploy.sh` 會自行偵測平台，
   偵測不到時同樣要帶 `TIGER_PLATFORM=`）——`02` 會起新的 redis。08 的 cron 與 09 的 unit **一定要**重新安裝
   （`all` 會做）：舊的 cron 行與 unit 沒有帶後端，purge 會每晚 ERROR，監控則每 30 秒重試、既不送心跳也不送告警。
4. **（AMD）手動把 OpenWebUI 的模型連線改到 Lemonade。** OpenWebUI 的連線設定是 PersistentConfig：
   新的 `docker-compose.backend-lemonade.yaml` 只在 OpenWebUI 資料庫**還沒有**連線設定時生效，
   既有 AMD 機器的資料庫裡仍指向已經不存在的 `http://ollama:11434`。請到 **Admin → Settings → Connections**：
   1. 關閉 **Ollama API**。
   2. 開啟 **OpenAI API**，新增連線，URL 填 `http://lemonade-edu:8800/api/v1`。
   3. Key 填這個指令印出的值（可能是空的，代表 Lemonade 沒開驗證，留空即可）：

      ```bash
      sudo docker exec openwebui-main printenv OPENAI_API_KEY
      ```

   4. 儲存後回到對話頁，確認模型清單出現 Lemonade 的模型。

   nvidia／arm64 的 Ollama 連線不變，不用動。
5. **（AMD）清理與改指向。** `/var/lib/ollama` 裡的 Ollama 模型不再使用，也不在任何備份裡；
   用 `sudo du -sh /var/lib/ollama` 確認大小，確定不需要後自行刪除。
   呼叫 `http://ollama:11434` 的 n8n workflow 或腳本（包含 07 的 smoke-test workflow）在 AMD 上要改指向 Lemonade。

**Rollback**：`renumber-migrate.sh` 不刪舊 volume（只印出刪除指令），bind mount 的模型（`/var/lib/ollama`、`MODELS_DIR`）
也從不被動到。要退回 v4.0.0：`down` 新模組、切回舊版程式，把遷移腳本搬走的模組層 `.env`（與挪到
`03-ai-core/ollama/.env` 的 `OLLAMA_*`）搬回原處，再照舊版流程部署；舊 project 名稱的 volume 仍在，會被接回。
部署舊版 03 之前，**先 `sudo docker rm -f redis`** 移除新版 02 建的 redis：舊版 02 沒有 redis service，
舊版 03 的 redis 也叫 `container_name: redis`，不先移除會撞名。**不要為此對 02 做 `down`**，那會連 postgres 一起停掉。
遷移後才寫進新 volume 的資料不會回到舊 volume，crontab 也要重新以舊版安裝。

行為變更（不需要動作，但要知道）：

- `03-ai-core/lemonade` 的 `restart` 會先拉 image 再重建，與 `all` 相同。
- `05-automation-n8n` 不帶 `N8N_AI_ASSISTANT_ENABLED` 的機器，升級後預設會啟動 sandbox（privileged DinD）；不要就明確設 `false`。

## Release Details

### Phase 03 成為推論後端層

推論引擎原本散在兩處：Ollama 在 OpenWebUI 模組裡、三平台都跑（AMD 走 Vulkan），Lemonade 在 `06` 而且只有 AMD 有。
本版把它們收到 `03-ai-core/` 底下，一台只部署一個：

| 平台 | `INFERENCE_BACKEND` | 部署的模組 |
|---|---|---|
| amd | `lemonade` | `03-ai-core/lemonade` |
| nvidia、arm64 | `ollama` | `03-ai-core/ollama` |

- `master-deploy.sh` 的 `DEPLOY_STEPS` 同時列出兩個後端，各自依 `INFERENCE_BACKEND` 決定部署或 SKIP（exit 0），所以順序不重要。
- 兩個後端的 compose 檔都用 `name:` 鎖住 project 名稱（`03-ai-core-ollama`、`03-ai-core-lemonade`），不受目錄名影響。
- 停止與查看類的動作（`down`、`status`、`logs`，lemonade 另有 `purge`）不看 `INFERENCE_BACKEND`，設定錯誤的機器仍停得下來。
- 以每個平台只有一個合法值而言，這個變數幾乎是多餘的；保留它是為了讓 03／04／07／08／09 的結構與上游一致，日後再加後端或再移植時能機械式套用。

### 部署時的後端切換

`03` 的 `deploy.sh all` 依序做：`pull` → 卸載本 stack 留下的另一個後端 → `up -d`。先拉 image，拉失敗時舊後端還在服務。

- 卸載前先**全部檢查**：同名容器若不屬於本 stack 的 compose project，整個部署停下，什麼都不動，請自行確認後移除。
- 自己的容器還掛在改名前的舊 project 時（沒跑 `renumber-migrate.sh`），直接停下並要求先跑遷移腳本。
- 被卸載的後端只移除容器，模型與 volume 都留著，並印出位置與大小。
- 主要會遇到的情況：AMD 機器跳過遷移腳本、還留著舊的 Ollama——部署 `03-ai-core/lemonade` 時會把它停掉移除。

### `renumber-migrate.sh`：一次性遷移

compose 的 project 名稱就是模組目錄名，改名之後舊容器還在（新目錄 `up` 會撞 `container_name`），
named volume 的前綴也變了（`openwebui_data`、n8n 的 `sandbox-api-data`、Lemonade 的三個 cache），
而 git 不會搬 gitignored 的模組層 `.env`，RAG 的 crontab 也寫死舊的絕對路徑。

- 第 0 段先驗證 `INFERENCE_BACKEND`：驗不過就是 CONFLICT，`--apply` 一項都不做——不會把服務停掉、卻因為設定錯誤而無法重新部署。判斷不出平台時請帶 `TIGER_PLATFORM=`。
- volume 用正在跑的 postgres／redis image 複製，不另外拉 image；複製前在新 volume 放「複製中」標記，核對檔案數成功才移除，中斷後重跑會偵測到並重做。
- n8n sandbox runner 的 DinD image cache 不搬（`cp -a` 會丟 overlayfs xattr），新 volume 會重新拉。
- 舊 volume 與舊目錄一律不刪，只印出刪除指令。

### Redis 搬到 `02-database`

Redis 由 n8n 的 queue 與 OpenWebUI 共用，搬到最先部署的資料庫層。跨 compose project 不能 `depends_on`，
所以 `04/deploy.sh` 在啟動 OpenWebUI 前等 redis healthy（最多 60 秒）。nvidia 的 `platform: linux/amd64` 一併搬到 `02/docker-compose.nvidia.yaml`。

### OpenWebUI：模型連線跟著後端

`OLLAMA_API_BASE_URL` 從 base compose 檔移除（overlay 刪不掉 base 的 key），改由 `deploy.sh` 疊
`docker-compose.backend-ollama.yaml` 或 `docker-compose.backend-lemonade.yaml`。
lemonade 的 overlay 關閉 Ollama API、開啟 OpenAI API 指向 `lemonade-edu:8800`，key 取 `LEMONADE_API_KEY`（可為空）。
這兩個都是 PersistentConfig，只影響全新安裝；既有 AMD 機器請照「升級注意」第 4 步手動改。

### n8n：SearXNG 一律部署

SearXNG 改為每台都部署，`deploy.sh` 在 n8n 之前單獨啟動它，失敗只警告，可用 `deploy.sh searxng` 單獨重試。
compose 裡仍保留 `profiles: ["searxng"]`：放進預設集合會被 n8n 的 `up` 一起帶起，SearXNG 一出錯就擋掉 n8n。
`N8N_AI_ASSISTANT_ENABLED` 改為預設 `true`，只控制 sandbox 與 n8n 是否接 SearXNG；設 `false` 會移除 sandbox 容器，SearXNG 照常執行。

### 健康檢查、purge 與監控綁定後端

- `07`：`INFERENCE_BACKEND` 是 `ollama` 才檢查 Ollama API；amd 的入口在 `lemonade` 時才跑 Phase 5（Lemonade Core）；空值或不認得的值列為 FAIL。
- `08`：`deploy.sh cron`／`purge` 先 resolve 後端，把生效值當參數傳給 purge 腳本，cron 那一行寫死後端、之後不再重新判斷。Lemonade 只重啟正在執行的容器（tiger-mode 刻意停掉其中一個）。
- `09`：`deploy.sh` 把後端寫進 unit 的 `Environment=TIGER_MONITOR_BACKEND`；daemon 不會自己猜，沒有後端就拒絕啟動。安裝改為 `enable` + `restart`，升級時一定換上新 daemon。

## 未納入本版的上游項目

本版移植自 Open-AI-Stack v5.0.0 的 compose 變更紀錄，以下項目刻意不搬：

- 上游新的預設推論後端 vLLM 與它的 model-manager，以及所有只為它們存在的部分：健康檢查階段、監控探測、Prometheus 設定與儀表板、purge 函式、`.env` 設定，以及相關的升級步驟。OpenGenie 只保留 `ollama` 與 `lemonade` 兩個後端；`INFERENCE_BACKEND=vllm` 會被當成不認得的值擋下。
- 上游專屬模組與其耦合的設定、image digest 釘版。
- 上游拆分成版本子目錄的 migrations 佈局：OpenGenie 的 `migrations/` 維持平面，升級步驟寫在本文「升級注意」。

上游空值 `INFERENCE_BACKEND` 會套用預設後端；OpenGenie 沒有那個預設，所以**空值一律是錯誤**。

### Ollama 版本注意

上游 v5.0.0 只以 digest 更新了 Ollama（`ollama/ollama:latest`）與 n8n（`n8nio/n8n:stable`），tag 未變；
OpenGenie 本來就跟著這兩個浮動 tag，不需要任何變更。請注意：**Ollama ≥ 0.40 第一次啟動時會升級模型儲存格式，之後要降回 0.40 以前的版本必須重新拉模型。**

## 驗證

未於實體 GPU 硬體上驗證。以下為實際執行過的檢查（皆在容器內執行）：

- `tests/inference-backend-test.sh`（`ubuntu:24.04`、stub 的 docker）：validate／resolve 3 平台 × 5 種值、cutover 的各種殘留情境、`03-ai-core/pre-deploy.sh`、`renumber-migrate.sh` 第 0 段、07 的健康檢查與 benchmark 分派、03 兩個 `deploy.sh` 的 SKIP 與 pull → 卸載 → up 順序、08 cron 行的安裝／取代／拒絕、09 unit 的 `Environment=` 與 systemctl 順序、05 的 SearXNG／sandbox 金鑰檢查、`master-deploy.sh pre-deploy` 收進 03、`.env` 帶 CRLF 或引號的 `INFERENCE_BACKEND`，共 327 項全數通過。
- 8 個含 compose 檔的模組（含兩個後端）在 amd／nvidia／arm64 三平台，以各自的 `.env.<platform>.example` 跑 `docker compose config -q`（含 `--profile '*'`），全數通過；`04` 疊兩種 backend overlay 的連線設定、`02` 的 redis 與 nvidia 的 `platform` 皆如預期。
- repo 內 47 支 shell 腳本 `bash -n` 全數通過；改過的腳本跑 shellcheck，沒有新增 warning。
- `deployments/compose-stack` 內（`migrations/` 與 `lib/common.sh` 以外）已無舊模組名。

## 已知限制

- **AMD 失去 Ollama。** AMD 的 Ollama 模型留在 `/var/lib/ollama` 不再使用；n8n workflow 與 07 的 smoke-test workflow 若打 `http://ollama:11434`，在 AMD 上要自己改指向 Lemonade。
- **OpenWebUI 的連線不會自動切換。** 既有 AMD 機器一定要做「升級注意」第 4 步。
- **`migrations/` 裡 v2.0.0 時期的兩支 DB 改名遷移腳本仍寫著舊模組路徑**（它們早已完成任務），升級後不要再執行。
- **[遷移指南](../MIGRATION.md) 尚未涵蓋 v5.0.0。** 本版的升級步驟以本文「升級注意」為準。
