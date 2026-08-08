# OpenGenie AI Stack v1.2.0

本版整合初始化與 hardware advisor 流程，讓第一次安裝、GPU driver 啟用後重開機，以及後續完整部署使用同一組可預期的指令；同時統一三種平台的 advisor 檔名與 tuning file 路徑。

## What's Changed

- `init` 改為會自行判斷 GPU driver 狀態的 self-guarding 流程。
- AMD、NVIDIA、ARM64 統一使用 `init → reboot → init → all`。
- pre-flight advisor 從 `tiger-advisor.sh` 更名為 `deploy.sh`。
- 修正 tuning file、NVIDIA environment example 與相關操作文件。
- [PR #10：consolidate files](https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/pull/10)

**Full Changelog**: [v1.1.0...v1.2.0](https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack/compare/v1.1.0...v1.2.0)

## Release Details

### Self-guarding init

過去安裝流程將 system setup、advisor 與 application deployment 分成容易混淆的命令。新的 `master-deploy.sh init` 會先偵測 GPU driver：

1. driver 尚未可用時，執行可重複安全執行的 system setup。
2. 安裝完成後提示重新開機並正常結束，不會在尚未載入 driver 時執行 advisor。
3. 重開機後再次執行 `init`，偵測到 driver 已啟用才執行 hardware advisor。
4. advisor 產生 tuning 設定後，以 `all` 部署完整 stack。

### Advisor 與 tuning file 統一

- 三種平台的 `00-pre-flight-advisor/tiger-advisor.sh` 更名為 `deploy.sh`。
- `deployments/tiger-deploy.sh` 與所有 skill 文件同步更新呼叫名稱。
- AMD／NVIDIA `master-deploy.sh` 修正 `TUNING_FILE` 路徑，與 ARM64 一樣讀取 stack 根目錄的 `tiger-tuning.env`。

### 環境與文件修正

- NVIDIA `.env.example` 修正誤植的 ARM64 標題。
- NVIDIA Docling 預設 image 從 CPU variant 改為 CUDA variant。
- 移除 NVIDIA／ARM64 中不屬於 OpenGenie 的 landing frontend／backend image 變數。
- installation、state machine、error recovery 與 full purge 文件統一採用新流程。

## Breaking Changes

- 直接呼叫 `00-pre-flight-advisor/tiger-advisor.sh` 的外部 automation 會失效，必須改為 `deploy.sh`。
- 舊的 `system → init → app` 操作順序已被 `init → reboot → init → all` 取代。

## 升級注意事項

- 更新任何引用舊 advisor 路徑的自訂腳本、排程或文件。
- 若舊版 tuning file 留在錯誤位置，先確認選定 profile，再將正確檔案放到對應 stack 根目錄。
- 第一次採用新流程時，依 driver 狀態接受可能的 reboot，不要在 reboot 前直接執行 `all`。

## 驗證重點

- 無 driver 的測試環境：`init` 應完成 setup、提示 reboot 並退出。
- driver 就緒的環境：`init` 應進入 advisor 並產生 stack 根目錄的 `tiger-tuning.env`。
- `all` 應讀取選定 profile，而不是無提示落回 conservative default。
