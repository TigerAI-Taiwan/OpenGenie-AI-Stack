# OpenGenie AI Stack v3.2.0

本版讓 Phase 編號、文件與實際部署順序重新一致。過去 `master-deploy.sh all`
刻意先執行 Phase 09 monitoring，再執行 Phase 08 backup/recovery；現在兩個模組
目錄互換名稱，順序與職責不變，但清單可直接按 00–10 閱讀。

**這是路徑破壞性版本。** 既有主機必須重新安裝 monitoring systemd unit 與
maintenance cron。請先閱讀[遷移指南](../MIGRATION.md)第 11 節。

## What's Changed

- `09-monitoring-alerting` 更名為 `08-monitoring-alerting`。
- `08-backup-recovery` 更名為 `09-backup-recovery`。
- `master-deploy.sh` 的 `DEPLOY_STEPS` 改為嚴格遞增的 00–10 順序。
- cron installer 自動改寫舊 `08-backup-recovery` 絕對路徑，並保留原排程。
- README、`llms.txt`、腳本 Path 註解、changelog 與遷移指南同步新路徑。

## Release Details

### 為什麼要更名

monitoring 必須先啟動，backup/recovery 隨後安裝每日 VRAM purge cron，讓監控能立即
觀察 purge 狀態。這個依賴順序沒有改變；更名只消除 Phase 09 → Phase 08 這個唯一的
逆序例外，避免人工逐模組部署與 `all` 得到不同順序，也避免維護者把它誤認為筆誤。

### 既有排程如何遷移

舊版 crontab 內含 repository 的絕對路徑，目錄更名後會指向不存在的腳本。
新版 `setup-cron.sh` 會偵測 `08-backup-recovery`，只替換路徑中的模組名稱，保留使用者
自訂的時間與 stdout/stderr 導向。monitoring systemd unit 同樣含絕對路徑，因此仍需
按遷移指南重新執行 monitoring deployer。

## 驗證

- 21 組 Docker Compose 設定成功展開：7 個 Compose 模組 × AMD／NVIDIA／ARM64。
- 14 個 JSON 資源通過解析。
- `git diff --check` 通過。

## 已知限制

- 本次未於實體 AMD、NVIDIA 或 ARM64 GPU 主機執行完整部署。
- Windows 測試環境無法啟動 WSL，因此未在本機執行 Bash `-n`；應在 Linux CI 或
  目標主機補跑所有 shell script 的語法檢查。
