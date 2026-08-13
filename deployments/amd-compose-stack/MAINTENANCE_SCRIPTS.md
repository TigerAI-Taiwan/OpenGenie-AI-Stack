# AMD Stack 維護腳本說明

## 唯一需要的腳本

### `fix-sh-format.sh` - 修正 Shell 腳本格式

**用途**: 修正所有 `.sh` 檔案的 Windows CRLF 格式問題

**何時使用**:
- 當您在 Windows 環境編輯過 `.sh` 檔案
- 在 Linux 執行腳本時出現 `/usr/bin/env: 'bash\r': No such file or directory` 錯誤

**如何使用**:
```bash
# 在 Linux 環境下執行
cd deployments/amd-compose-stack/
bash fix-sh-format.sh
```

**功能**:
- ✅ 自動找出所有 `.sh` 檔案
- ✅ 將 CRLF (`\r\n`) 轉換為 LF (`\n`)
- ✅ 設定正確的執行權限 (`chmod +x`)
- ✅ 顯示修正結果

---

## 其他重要檔案

### 配置檔案
- `.env` - Stack 全局配置（所有子目錄都會讀取）
- `master-deploy.sh` - 主部署腳本

### 文檔
- `CONFIG_FIX_COMPLETE.md` - 配置載入修正完成報告
- `DEPLOYMENT_ORDER.md` - 部署順序說明
- `README.md` - Stack 說明文檔

---

## 常見問題

### Q: 為什麼只有一個 fix 腳本？
**A**: 配置載入邏輯已經手動修正完成，不需要額外的修正腳本。只保留格式修正腳本即可。

### Q: 什麼時候需要執行 fix-sh-format.sh？
**A**: 
1. 在 Windows 編輯過 `.sh` 檔案後
2. 執行腳本時出現 `\r` 相關錯誤時
3. 從 Git 拉取更新後（如果 Git 自動轉換了換行符）

### Q: 如何避免 CRLF 問題？
**A**: 
1. 在 Git 中設定：`git config core.autocrlf input`
2. 使用支援 Unix 換行符的編輯器（如 VS Code 設定為 LF）
3. 在 Linux 環境下編輯 `.sh` 檔案

---

**維護者**: TigerAI Engineering  
**更新時間**: 2026-02-07
