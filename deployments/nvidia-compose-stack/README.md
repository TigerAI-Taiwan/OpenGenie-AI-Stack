# TigerAI Open-AI-Stack (NVIDIA CUDA Edition)

![Project Tier](https://img.shields.io/badge/Tier-P1_Mission_Critical-red)
![GPU](https://img.shields.io/badge/GPU-NVIDIA_CUDA_12.x-green)
![RTX](https://img.shields.io/badge/RTX_5090-Ready-green)
![Status](https://img.shields.io/badge/Status-Production-success)

Enterprise AI stack optimized for NVIDIA hardware, featuring **RTX 5090 support**, automated CUDA environment setup, and comprehensive monitoring.

## 🚀 Quick Start (一鍵部署)

### 1. Initialize Optimization Profile (Mandatory)
Investigate your hardware and select a profile (**Conservative** is default).
```bash
sudo bash master-deploy.sh init
```

### 2. Base System Installation
Installs Driver 580 (Alpha/Beta ppa), NVIDIA Toolkit, and Performance Services.
```bash
sudo bash master-deploy.sh system
sudo reboot
```

### 3. Complete Application Stack
Launches all Layers (Portainer, AI Interfaces, n8n, RAG, Monitoring).
```bash
sudo bash master-deploy.sh app
```

### 4. Direct Full Deployment
Or simply run everything in sequence:
```bash
sudo bash master-deploy.sh all
```

---

## 📦 Stack Components

### **Core Services**
| Layer | Service | Port | Status | Description |
|:------|:--------|:-----|:-------|:------------|
| **01** | Portainer | 9000 | ✅ | Docker管理介面 |
| **01** | WebSSH | 2222 | ✅ | Web終端機 |
| **02** | PostgreSQL | 5432 | ✅ | 主資料庫 (tigerai) |
| **02** | pgAdmin | 8000 | ✅ | 資料庫管理 |
| **03** | Ollama | 11434 | ✅ | LLM推論引擎 |
| **03** | OpenWebUI | 8080 | ✅ | AI聊天介面 (1+2 workers) |
| **03** | Redis | 6379 | ✅ | 快取與任務佇列 |
| **04** | n8n | 5678 | ✅ | 工作流自動化 (1+2 workers) |
| **05** | Mosquitto | 1883 | ✅ | MQTT訊息代理 |
| **05** | Qdrant | 6333 | ✅ | 向量資料庫 (GPU加速) |
| **05** | Docling | 5001 | ⚠️ | 文件處理 (需CPU x86-64-v2) |
| **10** | Grafana | 3000 | ✅ | 監控儀表板 |
| **10** | Prometheus | 9090 | ✅ | 指標收集 |
| **10** | cAdvisor | 8088 | ✅ | 容器監控 |
| **10** | Loki | 3100 | ✅ | 日誌聚合 |
| **10** | DCGM Exporter | - | ✅ | GPU指標匯出 |
| **11** | WUD | 3838 | ✅ | 容器更新監控 |

### **Key Features**
- ✅ **N8N_SECURE_COOKIE**: 已配置於所有 n8n 服務
- ✅ **Redis 隔離**: DB 0 (n8n), DB 1 (OpenWebUI)
- ✅ **Schema 隔離**: PostgreSQL 中的 `n8n` 和 `openwebui` schema
- ✅ **GPU 監控**: DCGM Exporter + Grafana 整合
- ✅ **自訂 Registry**: WUD 支援 docker.n8n.io

---

## 🌐 Service Access Matrix

| Service | URL | Credentials | Notes |
|:--------|:----|:------------|:------|
| **OpenWebUI** | http://localhost:8080 | - | AI 聊天介面 |
| **n8n** | http://localhost:5678 | - | 工作流編輯器 |
| **Grafana** | http://localhost:3000 | admin / CHANGE_ME | 監控儀表板 |
| **Prometheus** | http://localhost:9090 | - | 指標查詢 |
| **cAdvisor** | http://localhost:8088 | - | 容器監控 |
| **Portainer** | http://localhost:9000 | - | Docker 管理 |
| **pgAdmin** | http://localhost:8000 | - | 資料庫管理 |
| **WUD** | http://localhost:3838 | - | 容器更新監控 |
| **Qdrant** | http://localhost:6333 | - | 向量資料庫 API |

---

## ⚙️ Operations & Maintenance

| Action | Command | Description |
|:-------|:--------|:------------|
| **Initialize** | `sudo bash master-deploy.sh init` | 硬體檢測與效能調校 |
| **Check Status** | `sudo bash master-deploy.sh status` | 查看所有容器狀態 |
| **Verify System** | `sudo bash master-deploy.sh test` | 執行健康檢查 |
| **Backup Data** | `sudo bash master-deploy.sh backup` | 完整系統備份 |
| **Monitor GPU** | Access `http://localhost:3000` | 即時 VRAM/溫度/功耗 |
| **Stop All** | `sudo bash master-deploy.sh clean` | 停止並移除所有容器 |

---

## 🛠️ Performance Optimization

### **Hardware Integration (HWI)**
- **Dynamic Tuning**: 應用程式並發數 (n8n workers) 和 CPU 執行緒 (Lemonade) 根據 `init` profile 自動調整
- **Persistence Daemon**: 自動設定防止 GPU 電源狀態循環
- **CUDA Core**: Lemonade 引擎預配置 CUDA 加速

### **Database Configuration**
- **Schema Isolation**: `n8n` 和 `openwebui` 使用獨立 schema
- **Search Path**: 在資料庫層級設定，簡化應用程式連線字串

### **Redis Configuration**
- **DB Isolation**: n8n (DB 0 + prefix `n8n`), OpenWebUI (DB 1)
- **Health Check**: Redis 配置健康檢查確保服務可用性

---

## 🔧 Known Issues & Workarounds

### **Docling (05-rag-stack)**
- **問題**: 需要 CPU 支援 x86-64-v2 指令集 (SSE4.2, POPCNT)
- **影響**: KVM 虛擬機使用 "Common KVM processor" 模型時無法啟動
- **解決方案**: 
  1. 修改 KVM 虛擬機 CPU 模型為 `host-passthrough`
  2. 或暫時停用 Docling: `docker stop docling && docker rm docling`
- **狀態**: Qdrant 和 Mosquitto 正常運作

---

## 📊 Monitoring & Observability

### **Grafana Dashboards**
訪問 `http://localhost:3000` (admin / CHANGE_ME) 後可使用：

1. **匯入預設 Dashboard**:
   - **193** - Docker monitoring (cAdvisor)
   - **12239** - NVIDIA DCGM Exporter
   - **1860** - Node Exporter Full

2. **自訂 Dashboard**:
   - 已提供 Docker Containers Overview
   - 已提供 NVIDIA GPU Monitoring

### **Data Sources**
- ✅ Prometheus (預設)
- ✅ Loki (日誌)

---

## 🔐 Security Configuration

### **Credentials**
- **Grafana**: admin / CHANGE_ME
- **PostgreSQL**: adm / (from .env)
- **WUD**: 無驗證 (可自行配置)

### **Network**
- **Shared Network**: `ai_stack_net` (所有服務)
- **Host Access**: 所有服務配置 `host.docker.internal`

---

## 📂 Directory Structure

```
nvidia-compose-stack/
├── 00-pre-flight-advisor/      # 硬體檢測
├── 00-system-setup-nvidia-docker/  # NVIDIA 驅動與 Docker
├── 01-infra-webssh-portainer/  # 基礎設施
├── 02-database-postgres-pgadmin/  # 資料庫
├── 03-ai-interface-ollama-openwebui-redis/  # AI 介面
├── 04-automation-n8n/          # 工作流自動化
├── 05-rag-stack-docling-qdrant-mosquitto/  # RAG 堆疊
├── 06-ai-core-lemonade/        # AI 核心引擎
├── 10-observability-grafana/   # 監控與可觀測性
├── 11-lifecycle-wud/           # 容器生命週期管理
└── master-deploy.sh            # 主部署腳本
```

---

## 📖 Additional Documentation

- **Detailed Architecture**: See [SDD.md](./SDD.md)
- **Deployment Logs**: Check individual `deploy.sh` in each stack
- **Configuration Files**: `.env` files in each stack directory

---

## 🆘 Support & Troubleshooting

### **Common Commands**
```bash
# 查看所有容器狀態
docker ps

# 查看特定服務日誌
docker logs <container_name> -f

# 重啟特定服務
cd <stack_directory>
docker compose restart <service_name>

# 完全重建服務
docker compose down
docker compose up -d
```

### **Health Checks**
```bash
# 檢查 GPU
nvidia-smi

# 檢查 Docker GPU 支援
docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi

# 檢查網路
docker network inspect ai_stack_net

# 檢查資料庫連線
docker exec -it postgres psql -U adm -d tigerai
```

---

**Last Updated**: 2026-02-11  
**Maintained by**: TigerAI Team
