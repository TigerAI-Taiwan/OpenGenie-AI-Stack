# OpenGenie AI Stack v3.2.0

本版是一次上游修正的回移，主題同樣是「不會報錯的錯」：一個把不合法平台名放行的字串比對、
一個在非互動環境下讓整支腳本無聲中止的 `read`、一個讓 `clean` **裝上**監控服務的缺少分派，
以及一個從來沒有接上任何消費端的調校參數。四者都不會產生錯誤訊息，因此都是靠讀程式碼、
而不是靠故障回報找出來的。

**這不是破壞性版本**，`.env` 不需要更名任何變數。但有三處行為改變值得在升級前知道：
Redis 換 image、docling 換 image、以及硬體調校建議的 OpenWebUI worker 數**首次真正生效**。
詳見下方「升級注意」。

## What's Changed

- `lib/common.sh`：平台驗證由子字串比對改為等值迴圈，`TIGER_PLATFORM="amd nvidia"` 不再放行。
- `00-pre-flight-advisor`：非互動環境下不再中止，改為採用預設 profile 並輸出調校檔。
- `00-pre-flight-advisor`：輸出的 key 更名為 `TIGER_OWUI_UVICORN_WORKERS`，此建議值**首次生效**。
- `09-monitoring-alerting`：新增動作分派與 `uninstall` 動詞，`master-deploy.sh clean` 不再安裝並啟動監控。
- `09-monitoring-alerting`：`mosquitto-clients` 安裝失敗不再中止 `source`，降級路徑得以執行。
- `05-rag-stack`：不再產生 host 端的 `allow_anonymous true` broker 設定檔。
- `07-validation-stack`：`benchmark-tps.sh` 改用模組內 venv，不再動系統 Python。
- 新增 `OLLAMA_CONTEXT_LENGTH=32768`，避免 ollama 依 VRAM 自選 256k context。
- Redis 由 `redis/redis-stack-server:latest` 改為 `redis:8-alpine`。
- nvidia 的 docling 統一為 `cu130:v1.30.0`，與 `deploy.sh` 預拉的 image 一致。
- `06-ai-core-lemonade`：`lemonade-edu` 與 `lemonade-rag` 的 context 設定對齊；`lemonade-embed` 執行緒數改為推導。

## 升級注意

**Redis 換 image。** Redis 在本堆疊中只作為 KV 與 pub/sub 使用，資料屬快取性質，
**沒有 migration 步驟**。但 `redis-stack-server` 額外提供的 search / JSON / time-series
模組在 `redis:8-alpine` 中不存在——若你的環境有任何自訂元件依賴那些模組，它會**明確報錯**，
不會安靜降級。需要保留舊行為時在 `.env` 設 `REDIS_IMAGE=redis/redis-stack-server:latest`。

**docling 換 image（僅 nvidia）。** 從 `cu128:latest` 改為 `cu130:v1.30.0`，首次部署會
重新拉一顆數 GB 的 image。舊的 cu128 不會被自動移除，清除指引見
`skills/04-full-purge-procedure.md`。

**OpenWebUI worker 數首次生效。** 詳見下節；重跑 advisor 前請先讀。

## Release Details

### 平台驗證：子字串比對會放行不存在的平台

`case " ${TIGER_PLATFORMS[*]} " in *" ${TIGER_PLATFORM} "*)` 比對的是**陣列串接後的子字串**。
`TIGER_PLATFORMS=(amd nvidia arm64)` 串接為 `" amd nvidia arm64 "`，因此
`TIGER_PLATFORM="amd nvidia"` 是它的子字串，驗證通過並被 `export`。
之後 `tiger_compose` 會去找 `docker-compose.amd nvidia.yaml`——一個不存在的檔名。
陣列中**任何相鄰配對**都有同樣效果。

改為逐項等值比對。⚠️ 迴圈本體刻意寫成 `if`，不可簡化為
`[ "$_tp" = "$TIGER_PLATFORM" ] && _tp_ok=1`：在 `set -Ee` 與 ERR trap 之下，
它作為迴圈本體的**最後一句**時，最末次不匹配的迭代會回傳 1 並觸發 trap。

### advisor：`read` 在 EOF 會帶走整支腳本

`read` 在 EOF 回傳 1，而 `lib/common.sh` 設定了 `set -e`——中止發生在**下一行的
`CHOICE=${CHOICE:-1}` 之前**，所以預設值永遠沒有機會生效，`tiger-tuning.env` 完全不會被產生。
所有非互動呼叫端都踩得到：`tiger-deploy.sh`、`master-deploy.sh init`、管線、cron、CI。

現在以 `[ -t 0 ]` 判斷，非互動時記錄一行說明並採用 Conservative。

### advisor：OpenWebUI worker 建議值從來沒有生效過

advisor 一直輸出 `TIGER_OWUI_WORKERS`，但**全倉庫沒有任何消費者**。
`03-ai-interface/deploy.sh` 讀的是
`${TIGER_OWUI_UVICORN_WORKERS:-${OWUI_UVICORN_WORKERS:-2}}`，
名稱對不上，因此實際跑的一律是 fallback 的 `2`——選 BALANCED 或 OPTIMAL 都一樣。

`master-deploy.sh` 原有的註解只擔心「沒有 `tiger-tuning.env` 時的不對稱」，
沒有發現**有** `tiger-tuning.env` 時那個 key 也是空包彈。

現已更名為 `TIGER_OWUI_UVICORN_WORKERS`。這是**語意正確的名字**，不只是換字：
v3.0.0 起 OpenWebUI 是單一容器跑 `uvicorn --workers N`（upstream 的 Option B），
這個數字是**單一容器內的 process 數**，不是額外容器數。

⚠️ **這是行為改變。** 每個 uvicorn process 都是獨立載入的應用程式，記憶體不共用。
選 BALANCED（3）或 OPTIMAL（5）現在會真的開出那麼多 process，記憶體用量隨之上升。
數值本身維持 2 / 3 / 5 未動。

升級路徑是安全的：既有主機上的 `tiger-tuning.env` 帶的是舊 key，會被載入但無人讀取，
`03` 仍落到 `2`——與升級前的實際行為完全相同。**只有重跑 advisor 之後**新值才會生效。

### 監控：`clean` 會把監控裝起來

`09-monitoring-alerting/deploy.sh` **完全不接參數**，解析完腳本路徑就無條件執行
`sudo -E "$MONITOR_SCRIPT" install`。而 `master-deploy.sh clean` 對每個模組呼叫
`deploy.sh down`——於是「拆掉整個堆疊」這個動作會**安裝並啟動** `tiger-monitor.service`。
`tiger_monitor_main` 當時也只分派 `once | start | install`，連 `uninstall` 這個動詞都沒有可叫。

因此補的是**兩件事**：`deploy.sh` 端新增 `ACTION` 與 `case`（`down` 明確列出，
其餘含 `all` / `restart` 一律走既有的 install 路徑，保留未知參數的舊行為），
以及 `tiger-monitor-common.sh` 端新增 `uninstall`。

`uninstall` 以 unit 檔是否存在判斷「是否曾安裝」，好讓 `disable --now` 的退出碼
**不被吞掉**——吞掉失敗會留下一個仍在發警報的行程。unit 名稱已提取到函式頂端，
install 與 uninstall 共用，避免日後漂開。

### 監控：套件安裝失敗會中止 `source`

`sudo apt update && sudo apt install -y mosquitto-clients` 位於 `if` 本體的**最後一句**，
安裝失敗（無網路、套件被 hold、非 Debian 主機）時非零狀態向外傳遞，`set -e` 中止整個
`source`——於是兩行之後的降級（`MQTT_ENABLED=false`，繼續在本機探測服務）永遠到不了。
失敗模式因此是「監控完全不啟動」，而不是「監控啟動但不發佈」。加上 `|| true`。

`sudo` 刻意保留：常駐路徑是 `User=root` 不需要它，但手動執行 `once` 的情境仍在，拿掉是回歸。

### RAG：不再產生與實際生效相反的 broker 設定檔

`prep_rag_env` 會建立 `$MQTT_HOST_DIR/config/` 並寫入一份含 `allow_anonymous true`、
無密碼檔的 `mosquitto.conf`。v3.0.0 已把 compose 端改為直接掛載版控中的
`resource/_shared/mosquitto.conf`，因此**實際生效的設定是有認證的**——
v3.0.0 的說明沒有寫錯。

但那份 host 端檔案仍然每次部署都會被寫出來。它不再被掛進容器，卻是一份
**長得像真設定、內容與實際生效的那份完全相反**的檔案躺在磁碟上；有人開它排查 MQTT
問題，會得到「broker 是匿名開放的」這個錯誤結論。本版移除產生它的程式碼。

⚠️ **已存在於磁碟上的檔案不會被刪除**，見「已知限制」。

### 驗證工具：venv，不動系統 Python

`benchmark-tps.sh` 原本執行 `pip3 install requests --quiet`，打的是系統直譯器。
在近期的 Debian / Ubuntu 上那是 externally-managed 環境，不是直接失敗、就是動到
OS 擁有的 Python。改為在模組根目錄建立 `.venv`，與 `05-rag-stack` 的既有慣例一致
（`.gitignore` 一併補上 `.venv/`——在此之前 05 那個 venv 也沒有被 ignore）。

fallback 在 `python3 -m venv` 不可用時執行 `sudo apt-get install -y python3-venv`。
這是**明知的選擇**：它比被取代的 `pip3` 那行侵入性更低，且 `05-rag-stack/deploy.sh`
的 `setup_python_env` 本來就是這個做法。建立失敗留下的半成品目錄會先清掉再重試，
否則重試會沿用壞掉的 `pyvenv.cfg`。

### ollama context 上限

未設定時 ollama 依偵測到的 VRAM 自選 context 級距，在 128GB 統一記憶體的機器上會選
256k；乘上 `OLLAMA_NUM_PARALLEL` 與 `OLLAMA_MAX_LOADED_MODELS` 之後足以吃掉整台機器。
明確設為 32768。

### docling image：預拉的與實際跑的不是同一顆

`docker-compose.nvidia.yaml` 的預設是 `cu128:latest`，但 `deploy.sh` 的
`pull_docling_image` 預設是 `cu130:v1.30.0`，而該處註解自稱「overlay 的 inline default
是 cu130 pin 的單一事實來源」。兩者已經漂開：預拉的那顆與 compose 實際啟動的不是同一個 image。

統一到 `cu130:v1.30.0`（overlay、`.env.nvidia.example`、清除指引三處）。
⚠️ 查詢 registry 確認：`docling-serve-cu130` **沒有 `latest` tag**（僅 `vX.Y.Z`），
因此這個預設值**必須保持釘版本**。cu130 目前最新為 `v1.31.0`，本版刻意不一併升版——
此處要解決的是漂移，不是版本升級。

### `OMP_NUM_THREADS`：compose 無法表達「這個變數不該存在」

`${TIGER_CPU_THREADS:-}` 注入的是**空字串**，而 libgomp 會以 `Invalid value` 拒絕它，
不會退回預設值——比不設定更糟。裸鍵形式（`- OMP_NUM_THREADS`，無 `=`）從環境取值，
環境沒有時就什麼都不帶。

因此 `deploy.sh` 必須明確 **export 或 unset**：`sudo -E` 會原樣轉發 host 上的空值，
而裸鍵會把它撿起來。

### Lemonade：edu 與 rag 對齊，embed 的執行緒數改為推導

`lemonade-edu` 原為 `ctx_size 81920` / `--parallel 4`（每 slot 20480 tokens），
約 30k tokens 的 system prompt 會超過單 slot 上限。改為 `131072` / `--parallel 2`
（每 slot 65536），與 `lemonade-rag` 一致。

`lemonade-embed` 原本寫死 `--threads 8`，且 `TIGER_CPU_THREADS` 根本沒有傳進該服務。
現在傳入並取一半，避免與 edu / rag 爭搶同一批核心。⚠️ **下限 1 是必要的**：
llama.cpp 把 `--threads 0` 解讀為「自動偵測」並吃掉每一顆核心。

## 未納入本版的上游項目

上游變更記錄共 13 項，其中 4 項刻意不搬：

- **OWUI worker 數 5 → 4**：上游的理由是「每個 process 常駐約 500MB」與對齊其 k3s 側的
  記憶體上限。這兩個前提都與本堆疊的硬體無關，需要在自己的機器上重新評估，
  不是照抄一個數字。本版只修好名稱，數值未動。
- **`08` / `09` 順序調換**：已於 `331c10f`（#21）完成，僅確認未再改動。
- **broker 帳號對齊**：本堆疊已改用 stack 層的 `MQTT_USERNAME` / `MQTT_PASSWORD`，
  比上游的做法更徹底。
- **arm64 關閉 docling GPU**：這是 GB10（`sm_121`，PyPI PyTorch 僅編到 `sm_120`）的
  專屬發現。本堆疊的 arm64 overlay 標定的是 Jetson / Grace-Hopper class 硬體，
  在真的 `sm_120` 以下的板子上照搬是**純退步**。同一份 overlay 中 qdrant 的 GPU
  reservation 亦未受影響。

上游另有一項 `mosquitto.conf` 移除 websockets listener 的變更，對本堆疊是 no-op：
`resource/_shared/mosquitto.conf` 沒有 `listener 9001`，也沒有 `acl_file`。

## 驗證

未於實體 GPU 硬體上驗證。以下為實際執行過的檢查：

- `bash -n`：六支改動過的腳本全數通過。`shellcheck -S warning` 僅餘 4 條**既有**告警
  （SC2034 / SC2155），無一來自本版改動。
- **平台驗證雙向實測**：`TIGER_PLATFORM="amd nvidia"` → rc=1 並印出 ERROR；
  `TIGER_PLATFORM=nvidia` → rc=0。
- **`OMP_NUM_THREADS` 裸鍵三態實測**（`docker compose config`，nvidia overlay）：
  未設定 → `null`（不注入）；`OMP_NUM_THREADS=12` → `"12"`；`OMP_NUM_THREADS=` → `""`。
  第三種正是 `deploy.sh` 的 `unset` 分支要擋的情況，確認擋得到。
- **docling image 一致性**：`docker compose config` 解析出
  `ghcr.io/docling-project/docling-serve-cu130:v1.30.0`，與預拉的 ref 相同。
- **registry 事實查核**：查詢 ghcr 確認 cu130 無 `latest` tag（104 個 tag）、
  `v1.30.0` manifest 回 200、cu128 則確實有 `latest`。
- `03` 與 `06` 的 `docker compose config` 解析通過，
  `OLLAMA_CONTEXT_LENGTH: "32768"`、`image: redis:8-alpine` 如預期。
- `grep` 確認：三份 `.env.*.example` 各有一筆 `OLLAMA_CONTEXT_LENGTH`、
  `REDIS_IMAGE` 三份一致、`05/deploy.sh` 已無 `allow_anonymous`。

⚠️ **以下兩項僅有靜態檢查，未實際執行**，需要在 Linux 主機上補跑：

- advisor 的非互動路徑（需 `nproc` / `free`）：`bash 00-pre-flight-advisor/deploy.sh < /dev/null`
- 監控的 `down` 路徑（需 systemd）：`sudo bash 09-monitoring-alerting/deploy.sh down`，
  接著確認 `/etc/systemd/system/tiger-monitor.service` 已不存在。

## 已知限制

- **既有主機上殘留的 `mosquitto.conf` 不會被清除。** 本版只停止產生它，
  `$MQTT_HOST_DIR/config/mosquitto.conf`（預設 `~/TigerAI/mosquitto/config/`）
  若已存在會原封留著。它不會被掛進容器、不影響安全性，但**內容與實際生效的設定相反**。
  需要時請手動移除。
- **`.env.{nvidia,arm64}.example` 會把 docling image 釘死。**
  `05/deploy.sh` 的註解宣稱這兩份 example 刻意把 `DOCLING_IMAGE` 留成註解，
  以免使用者手上的 `.env` 在 overlay 升版後靜默釘住舊 image——**但實際上兩份都是賦值**。
  因此複製出來的 `.env` 仍會釘住本版的 `v1.30.0`。本版未變更此行為。
- **advisor 的 worker 數值未經本堆疊硬體驗證。** 2 / 3 / 5 是名稱修好之前就存在的數字，
  在此之前從未真正套用過，因此也從未被實測過。首次選用 OPTIMAL 前建議觀察記憶體用量。
- **arm64 的 docling 仍使用 GPU reservation。** 若你的目標板子確實是 GB10（`sm_121`），
  Triton lowering 會硬失敗，需自行改為 CPU；本版刻意不預設關閉。
