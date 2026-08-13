# ============================================================================
# AMD Stack 部署順序說明
# ============================================================================

## 正確的執行順序

### 首次部署（Fresh Installation）

```bash
# Step 1: 安裝 ROCm 驅動和 Docker Runtime
sudo ./master-deploy.sh system

# Step 2: 重啟系統（讓驅動生效）
sudo reboot

# Step 3: 重啟後，執行硬體檢測
sudo ./master-deploy.sh init

# Step 4: 部署所有應用服務
sudo ./master-deploy.sh app
```

### 已有 ROCm 環境

```bash
# 直接執行完整部署
sudo ./master-deploy.sh all
```

## 目錄編號說明

- `00-pre-flight-advisor`: 硬體檢測工具（需要 GPU 驅動已安裝）
- `00-system-setup-rocm-docker`: ROCm 驅動安裝（必須最先執行）

**注意**: 兩個都是 `00-` 開頭，但 `master-deploy.sh` 中的 `DEPLOY_STEPS` 陣列已經按正確順序排列。

## 修正建議

為了避免混淆，建議將目錄重新命名：

```bash
# 選項 A: 使用字母後綴
00a-system-setup-rocm-docker
00b-pre-flight-advisor

# 選項 B: 使用更早的編號
00-system-setup-rocm-docker
01-pre-flight-advisor
02-infra-webssh-portainer  # 原 01
...
```

目前 `master-deploy.sh` 的執行邏輯已經正確處理了順序問題。
