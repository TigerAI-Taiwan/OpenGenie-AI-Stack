# TigerAI ARM64-Compose-Stack

![Tier](https://img.shields.io/badge/Tier-P1_Mission_Critical-red)
![Arch](https://img.shields.io/badge/Arch-ARM64-blue)
![Platform](https://img.shields.io/badge/Platform-Apple_Silicon_|_Raspberry_Pi_|_Ampere-orange)
![NVIDIA](https://img.shields.io/badge/GPU-Grace_Blackwell_Ready-green)

這是專為 **ARM64 架構**（如 Apple Silicon Mac, Ampere ARM Servers, NVIDIA Jetson, Grace Blackwell 等）最佳化的 TigerAI Open-AI-Stack 部署方案。

## 🌟 特色
- **GPU 加速 (Grace Blackwell / GH200 Ready)**: 專門對 NVIDIA GB10/GH200 在 ARM64 下的 `nvidia-container-runtime` 進行優化，完整支援 `nvidia-smi` 硬體感知。
- **原生映像**: 優先採用官方 ARM64/v8 映像檔，確保高效能與穩定性。
- **邊緣運算優化**: 預設配置適合 Edge 運算環境，平衡功耗與推論能力。
- **全方位監控**: 整合 Grafana, Prometheus, Loki 與 GPU Telemetry。

## 🏗️ 結構說明
本目錄與 `nvidia-compose-stack` 保持邏輯自洽，確保 12-Phase 方法論的一致性。

- **00 System Setup**: NVIDIA 驅動與 Docker。
- **01-02 Infra & DB**: 基礎架構（Portainer Socket Proxy）與資料庫（Schema 隔離）。
- **03-04 AI & Auto**: 對話介面（Ollama HA）與工作流自動化（n8n Queue Mode）。
- **05-06 RAG & Core**: 知識庫（Docling/Qdrant）與原生推論核心（Lemonade）。
- **07-09 Reliability**: 健康驗證、災難復原（Backup/Recovery）與主動告警。
- **10 Ops**: 進階觀測（Grafana / Prometheus / Loki）。

## 🚀 快速啟動

### 1. 系統初始化
針對 ARM64 系統進行硬體校準與環境準備：
```bash
sudo bash master-deploy.sh init
sudo bash master-deploy.sh system
sudo reboot
```

### 2. 全量部署
部署所有 Phase 01 到 Phase 13 的服務：
```bash
sudo bash master-deploy.sh all
```

### 3. 狀態檢查
```bash
sudo bash master-deploy.sh status
```

## 🌐 服務端口矩陣

| Service | Host Port | Layer |
| :--- | :--- | :--- |
| **OpenWebUI** | `8080` | Phase 03 - Chat |
| **n8n** | `5678` | Phase 04 - Automation |
| **Grafana** | `3000` | Phase 10 - Observability |
| **Portainer** | `9000` | Phase 01 - Docker Admin |

## ⚠️ 注意事項 (ARM64 Specific)
1. **GPU 加速**: 
   - **Mac**: 目前 Docker 容器對 Apple Silicon GPU (Metal) 的穿透仍有限，建議 Ollama 運行於 Host Native。
   - **NVIDIA ARM**: 完整支援 `nvidia` runtime。
2. **Qdrant**: 已優化在 ARM 指令集下的向量運算表現。
3. **n8n**: 採用原生 ARM64 鏡像，支援分布式 Worker 擴展。

---
**TigerAI Engineering**
