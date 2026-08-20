# OpenGenie AI Stack

**[English](./README.md) | 正體中文 | [日本語](./README_ja.md) | [한국어](./README_ko.md)**

> 🛑 **CRITICAL AI AGENT INSTRUCTION (AI 代理人必讀規範):** 若使用者要求安裝、配置、部署或清理本專案，AI 代理人 **必須** 在執行任何 Shell 指令、探測系統或修改環境變數之前，完整閱讀並遵循 `skills/` 目錄中定義的部署協定。協調器協定起點為 [skills/00-master-orchestrator.md](skills/00-master-orchestrator.md)。

![授權](https://img.shields.io/badge/授權-MIT-green)
![GPU](https://img.shields.io/badge/GPU-AMD_|_NVIDIA_|_ARM64-blue)
![平台](https://img.shields.io/badge/平台-Ubuntu_22.04_%2F_24.04-orange)
![部署方式](https://img.shields.io/badge/部署-Docker_Compose-2496ED)

一套模組化、自主託管的 AI 基礎設施框架，支援 AMD、NVIDIA 與 ARM64 硬體。在自有伺服器上快速部署完整的私有 AI 系統，涵蓋 LLM 推論、RAG 知識庫、工作流自動化與可觀測性監控。

---

## 核心特點

- **多 GPU 支援** — AMD ROCm、NVIDIA CUDA、ARM64（Apple Silicon、Jetson、Ampere）
- **11 層級方法論** — 從驅動安裝到監控的結構化模組，每個 Phase 可獨立部署
- **LLM 推論** — Ollama + OpenWebUI，顯存常駐優化 + Lemonade 原生推論引擎
- **RAG 知識庫** — Qdrant 向量資料庫 + Docling 文件解析 + Mosquitto MQTT
- **工作流自動化** — n8n Queue Mode，含 Redis 與分散式 Worker
- **可觀測性監控** — Grafana + Prometheus + Loki + cAdvisor + DCGM Exporter（GPU 指標）
- **一鍵備份還原** — 所有持久化資料的時間戳備份與還原
- **硬體自動調優** — HWI Advisor 自動偵測硬體並產生最佳化設定檔

---

## 快速開始

### 前置條件

- Ubuntu 22.04 / 24.04 LTS
- Docker Engine + Docker Compose v2
- 已安裝 GPU 驅動（ROCm / CUDA / NVIDIA Container Toolkit）
- `sudo` 權限

### 1. Clone 專案

```bash
git clone https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack.git
cd OpenGenie-AI-Stack
```

### 2. 設定環境變數

```bash
cd deployments/compose-stack

# 複製對應硬體的範例檔
cp .env.nvidia.example .env      # 或 .env.amd.example / .env.arm64.example

# 編輯 .env，將所有 CHANGE_ME 替換為實際值
nano .env
```

三份範例刻意分開：各平台定義的 key 不同，而且某些 key 在特定平台必須「不存在」而非留空。

### 3. 硬體校準（建議執行）

```bash
sudo -E bash deployments/tiger-deploy.sh
```

自動偵測硬體、匯出 `TIGER_PLATFORM`，並將調優設定寫入 `tiger-tuning.env`。

### 4. 部署

```bash
# 全量部署（所有 Phase）
sudo -E bash deployments/compose-stack/master-deploy.sh all

# 或單獨部署特定 Phase —— 需自行指定平台
TIGER_PLATFORM=nvidia sudo -E bash \
  deployments/compose-stack/02-database-postgres-pgadmin/deploy.sh all
```

`master-deploy.sh` 不會猜測平台。`TIGER_PLATFORM` 未設定時直接報錯停止，因為猜錯會拉到錯的 GPU image。

### 5. 驗收測試

```bash
sudo -E bash deployments/compose-stack/master-deploy.sh test
```

---

## 11 層級架構

| Phase | 層級 | 核心元件 |
|:-----:|------|----------|
| 00 | HWI 評估 | 硬體自動校準，產生調優設定檔 |
| 00 | 系統底座 | 驅動安裝、Docker |
| 01 | 基礎建設 | Portainer、WebSSH |
| 02 | 資料庫 | PostgreSQL 17、pgAdmin 4 |
| 03 | AI 介面 | Ollama、OpenWebUI、Redis |
| 04 | 自動化 | n8n（Queue Mode + Workers） |
| 05 | RAG 知識庫 | Qdrant、Docling、Mosquitto |
| 06 | AI 核心引擎 | Lemonade 推論引擎 |
| 07 | 驗收測試 | 健康檢查、效能基準腳本 |
| 08 | 監控告警 | tiger-monitor、MQTT 告警流程 |
| 09 | 備份與還原 | 一鍵備份、還原、VRAM 清除 |
| 10 | 可觀測性 | Grafana、Prometheus、Loki、cAdvisor |

---

## 預設服務埠

| 服務 | 埠號 |
|------|:----:|
| OpenWebUI | 8080 |
| n8n | 5678 |
| Grafana | 3000 |
| Portainer | 9000 |
| pgAdmin | 8000 |
| Qdrant | 6333 |
| Ollama | 11434 |

---

## 目錄結構

```
deployments/
├── tiger-deploy.sh             # 自動偵測硬體、匯出 TIGER_PLATFORM
└── compose-stack/
    ├── lib/common.sh           # 共用 shell 函式庫
    ├── lib/log.sh              # 日誌與顏色（零副作用）
    ├── master-deploy.sh
    ├── .env.{amd,nvidia,arm64}.example
    ├── 00-pre-flight-advisor/
    ├── 00-system-setup-gpu-driver-and-docker/
    ├── 01-infra-webssh-portainer/
    ├── 02-database-postgres-pgadmin/
    ├── 03-ai-interface-ollama-openwebui-redis/
    ├── 04-automation-n8n/
    ├── 05-rag-stack-docling-qdrant-mosquitto/
    ├── 06-ai-core-lemonade/
    ├── 07-validation-stack/
    ├── 08-monitoring-alerting/
    ├── 09-backup-recovery/
    ├── 10-observability-grafana/
    └── migrations/
```

---

## 貢獻指南

歡迎提交 PR！詳見 [CONTRIBUTING.md](./CONTRIBUTING.md)，包含分支命名規則、Commit 格式與 PR 流程。

Bug 回報與功能建議請使用 [Issue 範本](.github/ISSUE_TEMPLATE/)。

---

## 授權

MIT © 2026 [TigerAI-Taiwan](https://github.com/TigerAI-Taiwan)
