# OpenGenie AI Stack v3.0.0

本版將 `amd`／`nvidia`／`arm64` 三份重複的 compose stack 合併為單一
`deployments/compose-stack/`，平台改由執行期的 `TIGER_PLATFORM` 決定，不再由
「部署哪個目錄」決定。合併過程中清出多項因三份副本各自漂移而產生的既有缺陷。

**這是破壞性版本。** 既有環境升級前請閱讀
[v2 → v3 遷移指南](../MIGRATION.md)：Ollama 模型、OpenWebUI worker、Lemonade
systemd 服務與 MQTT 認證都需要動作，其中 MQTT 未設定憑證會直接停止運作。

## What's Changed

- 三份 compose stack 合併為 `deployments/compose-stack/`，以 `TIGER_PLATFORM` 選擇平台。
- 新增 `lib/common.sh`：ERR trap、env 三層載入、`tiger_compose`、`tiger_res`。
- 新增 `lib/log.sh`：`LOG`/`SKIP`/`WARN`/`ERROR` 與顏色的唯一來源。零副作用（不 `set`、不裝 trap、不要求 `TIGER_PLATFORM`），因此 host-side 腳本（`install.sh`、backup/restore、`setup-cron.sh`、`migrations/*`）與 `lib/common.sh` 共用同一份實作。
- OpenWebUI 改為單一容器多 uvicorn worker，並新增一次性的 `openwebui-migrate`。
- Lemonade 收斂為 AMD 專屬模組。
- MQTT broker 啟用認證。
- 新增 `docs/MIGRATION.md`。

## Release Details

### 單一 stack 與 `TIGER_PLATFORM`

舊版三份 stack 有大量逐字相同的檔案，任何修正都必須手動同步三次——而實際上
經常只改了其中一份。合併後平台差異集中在
`docker-compose.<platform>.yaml` 與 `resource/<platform>/`，其餘共用。

`master-deploy.sh` 不會猜測平台：`TIGER_PLATFORM` 未設定時直接報錯停止，避免
拉到錯的 GPU image。cron 與 systemd 因為環境近乎空白，安裝時會把平台值寫入
排程條目與 unit 檔。

### OpenWebUI：worker 容器改為容器內多行程

舊版以額外容器擴展（nvidia 兩個寫死、amd/arm64 一個可 scale）。uvicorn 在
`workers>1` 時是 spawn 而非 fork，每個 worker 都會重新 import 整個 app，而
OpenWebUI 在 import 期執行 Alembic migration——等於 N 個並行的
`alembic upgrade head` 打同一個資料庫，且失敗會被 `except Exception` 吞掉。

改為單一 `openwebui-main` 執行 `uvicorn --workers N`，並由一次性的
`openwebui-migrate` 先跑完 migration。worker 數量改用 `OWUI_UVICORN_WORKERS`。

### Lemonade 收斂為 AMD 專屬

nvidia 與 arm64 的 `.env.example` 從未定義任何 Lemonade 變數，其 systemd 服務
一直以寫死的 fallback 執行。該模組現在只在 amd 部署；另外兩個平台的 LLM 推論
由 Phase 03 的 Ollama 負責。

⚠️ 升級不會自動移除既有的 systemd unit，需手動卸載，見遷移指南。

### MQTT broker 啟用認證

舊版由 `deploy.sh` 產生 `allow_anonymous true` 且無密碼檔的設定，任何能連到
1883 埠的對象都可讀寫，而 healthcheck 卻傳送著從未被驗證的憑證。現在設定檔
隨版控提供，密碼檔在容器啟動時生成，`MQTT_USERNAME` / `MQTT_PASSWORD` 由
broker、healthcheck、`tiger-monitor.sh` 與 `monitor_device.py` 共用。

### 合併過程中修正的既有缺陷

多數屬於「三份副本漂移、只有一份是對的」：

- `check-health.sh` 以 `grep -q` 比對 `"200|401"`，基本 grep 將 `|` 視為字面
  字元，因此 nvidia／arm64 的 Lemonade 檢查即使服務正常也一律回報 FAIL。
- amd 的 `tiger-monitor.sh` 檢查函式是空殼，systemd 服務每 60 秒空轉——amd
  主機從未真正被監控。nvidia 版則缺少「服務失敗時告警」的分支。
- nvidia 沒有 Phase 08 的 `deploy.sh`，備份與還原腳本從未被賦予執行權限。
- `tiger-monitor.sh` 發布時未帶憑證、不檢查發布失敗、探測使用 `curl -s`
  （HTTP 500 也算通過），且只涵蓋 10 個服務中的 6 個。
- `monitor_device.py` 預設連接埠為 9013，該埠在本堆疊中無人監聽。
- `rocm-smi-collector.sh` 在 host 上呼叫未安裝的 `rocm-smi`，每分鐘產出一份
  全為 0 的指標，而兩份 dashboard 正在讀取它。已移除，改用官方 exporter。
- `00-pre-flight-advisor` 只讀取第一張 GPU 的 VRAM，且輸出寫往相對於呼叫者
  工作目錄的路徑。
- 資料庫 migration 腳本以已不存在的 compose 檔名強制停止應用程式，會使
  `pg_dump` 期間的停止動作靜默失效。

### n8n 健康檢查改用 readiness

`/healthz` 在程序啟動後即回 200，與資料庫狀態無關；`/healthz/readiness` 在
資料庫尚未連線或 migration 未完成時回 503。compose healthcheck、監控與驗收
檢查皆已改用後者。

## 已知限制

- 本版尚未於實體 GPU 硬體上驗證。所有驗證為靜態檢查：三平台
  `docker compose config` 展開、`bash -n`、路徑解析與不變量檢查。
- `monitor_device.py` 發布的 `device/gpu/metrics` 在本專案中無消費端。
