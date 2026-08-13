# ROCm + Docker 安裝

## 📁 目錄內容

```
00-system-setup-rocm-docker/
├── deploy.sh     ← 唯一需要的安裝腳本
├── .env          ← 本地配置（可選）
└── README.md     ← 本說明文檔
```

## 🚀 使用方法

```bash
cd deployments/amd-compose-stack/00-system-setup-rocm-docker/
sudo bash deploy.sh
```

## ✅ 功能

### 自動安裝
- ✅ ROCm 7.2.70200
- ✅ Docker CE
- ✅ Kernel Headers

### GPU 效能優化
- ✅ 防止 GPU 睡眠
- ✅ 設定效能模式為 `high`
- ✅ 禁用螢幕保護
- ✅ 開機自動執行優化

### 智慧判定
- ✅ 已安裝的組件會自動跳過
- ✅ 失敗後可重新執行
- ✅ 只安裝缺少的部分

## ⚙️ 配置

### 配置載入順序

```
1. 本地 .env (00-system-setup-rocm-docker/.env)  ← 先載入
   ↓
2. 父目錄 .env (amd-compose-stack/.env)     ← 後載入（覆蓋本地）
   ↓
3. 腳本預設值                                ← 最後備援
```

**重要**：父目錄的 `.env` 會覆蓋本地 `.env` 的同名變數。

### 可配置的變數

在 `.env` 檔案中可以設定：

```bash
# ROCm 版本
ROCM_VERSION=7.2.70200
ROCM_DEB_URL=https://repo.radeon.com/amdgpu-install/7.2.70200/ubuntu/noble/amdgpu-install_7.2.70200-1_all.deb

# 系統調校
VM_MAP_COUNT=2097152
SET_PERF_LEVEL=high
```

## 📋 安裝完成後

```bash
# 1. 重啟系統
sudo reboot

# 2. 驗證安裝
rocm-smi              # 查看 GPU
docker --version      # 查看 Docker
docker ps             # 測試 Docker

# 3. 檢查效能服務
sudo systemctl status rocm-gpu-performance.service
```

## 🔧 進階操作

### 手動執行 GPU 效能優化
```bash
sudo /usr/local/bin/rocm-gpu-performance.sh
```

### 查看服務日誌
```bash
sudo journalctl -u rocm-gpu-performance.service
```

### 禁用效能服務（如需要）
```bash
sudo systemctl disable rocm-gpu-performance.service
```

---

**就這麼簡單！** 🎯
