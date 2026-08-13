# SDD: ARM64-Compose-Stack

## 📝 Document Metadata
*   **Project Name:** Open-AI-Stack (ARM64 Optimized)
*   **Tier:** P1 (Mission Critical Infrastructure)
*   **Target Hardware:** Apple Silicon / NVIDIA Grace Blackwell / Ampere ARM
*   **Software Stack:** Docker Compose, NVIDIA Container Toolkit (for ARM64)
*   **Status:** Synchronized with NVIDIA Stack

---

## 1. 架構摘要
本堆疊是 TigerAI Open-AI-Stack 在 ARM64 架構下的原生實作。主要針對 **Apple Silicon** 與 **Enterprise ARM (Ampere)** 伺服器進行優化，並完整支持 **NVIDIA ARM (Blackwell)** 系列。

## 2. 核心特性 (v2.0 Synchronized)
- **分層方法論**: 從底層驅動到可觀測性的全流程覆蓋。
- **n8n Queue Mode**: 整合 Redis 隊列與分布式 Worker 支援。
- **PostgreSQL 硬化**: 強制 Schema 隔離 (n8n/openwebui) 與 5432 埠隱藏。
- **進階觀測性**: 整合 Grafana, Prometheus 與 Loki，支持 ARM64 系統與 NVIDIA GPU 監控。

## 3. 模組詳情
- **Phase 00**: 針對 **NVIDIA Grace Blackwell (GB200/GB10) / GH200** 優化，安裝對應之 ARM64 驅動。
- **Phase 03**: Ollama HA 配置，支持 `nvidia` runtime 與並發推論。
- **Phase 04**: n8n 企業級配置，支援檔案系統白名單與安全 Cookie。
- **Phase 06**: Lemonade Core 推論引擎，支持 CUDA ARM64 後端。
- **Phase 10**: 完整監控指標，包含 cAdvisor (8088) 與 DCGM Exporter。

## 4. 資源分配建議
- **CPU**: 建議保留至少 20% 核心給 OS 與監控系統。
- **RAM**: 考慮 ARM 統一內存特性，建議針對模型大小動態調整容器限制。

## 5. 目標平台
- Mac Studio / Mac Mini (Native Docker)
- NVIDIA Jetson AGX Orin / IGX
- AWS Graviton 3/4
- NVIDIA Grace Blackwell (GB200)
