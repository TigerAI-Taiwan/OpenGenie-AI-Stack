# OpenGenie AI Stack

**[正體中文](./README_zh.md) | [日本語](./README_ja.md) | [한국어](./README_ko.md)**

> 🛑 **CRITICAL AI AGENT INSTRUCTION:** If the user requests to install, configure, deploy, or purge this project, the AI Agent **MUST** read and follow the deployment protocols defined in the `skills/` directory BEFORE executing any shell command, probing the system, or modifying environment variables. The orchestrator protocol starts with [skills/00-master-orchestrator.md](skills/00-master-orchestrator.md).

![License](https://img.shields.io/badge/License-MIT-green)
![GPU](https://img.shields.io/badge/GPU-AMD_|_NVIDIA_|_ARM64-blue)
![Platform](https://img.shields.io/badge/Platform-Ubuntu_22.04_%2F_24.04-orange)
![Stack](https://img.shields.io/badge/Stack-Docker_Compose-2496ED)

A modular, self-hosted AI infrastructure framework for AMD, NVIDIA, and ARM64 hardware. Deploy a full-stack private AI appliance — LLM inference, RAG pipeline, workflow automation, and observability — on your own hardware in minutes.

---

## Features

- **Multi-GPU Support** — AMD ROCm, NVIDIA CUDA, ARM64 (Apple Silicon, Jetson, Ampere)
- **11-Phase Methodology** — structured, independently deployable modules from driver setup to monitoring
- **LLM Inference** — Ollama + OpenWebUI with always-ready VRAM optimization and Lemonade native engine
- **RAG Pipeline** — Qdrant vector DB + Docling document processor + Mosquitto MQTT
- **Workflow Automation** — n8n in queue mode with Redis and distributed workers
- **Observability** — Grafana + Prometheus + Loki + cAdvisor + DCGM Exporter (GPU metrics)
- **One-Click Backup** — timestamped backup and restore for all persistent data
- **Auto Hardware Tuning** — HWI Advisor auto-detects hardware and generates optimal config

---

## Quick Start

### Prerequisites

- Ubuntu 22.04 / 24.04 LTS
- Docker Engine + Docker Compose v2
- GPU drivers installed (ROCm / CUDA / NVIDIA Container Toolkit)
- `sudo` access

### 1. Clone

```bash
git clone https://github.com/TigerAI-Taiwan/OpenGenie-AI-Stack.git
cd OpenGenie-AI-Stack
```

### 2. Configure

```bash
cd deployments/compose-stack

# Copy the example matching your hardware
cp .env.nvidia.example .env      # or .env.amd.example / .env.arm64.example

# Edit .env — replace all CHANGE_ME values with your own credentials
nano .env
```

The three examples are kept separate on purpose: the platforms define
different keys, and some keys must be absent rather than empty.

### 3. Hardware calibration (recommended)

```bash
sudo -E bash deployments/tiger-deploy.sh
```

This detects your hardware, exports `TIGER_PLATFORM`, and writes a tuning
profile to `tiger-tuning.env`.

### 4. Deploy

```bash
# Full deployment (all phases)
sudo -E bash deployments/compose-stack/master-deploy.sh all

# Or deploy an individual phase — set the platform yourself
TIGER_PLATFORM=nvidia sudo -E bash \
  deployments/compose-stack/02-database-postgres-pgadmin/deploy.sh all
```

`master-deploy.sh` refuses to guess the platform. If `TIGER_PLATFORM` is
unset it stops with an error rather than picking one, because guessing wrong
pulls the wrong GPU image.

### 5. Verify

```bash
sudo -E bash deployments/compose-stack/master-deploy.sh test
```

---

## 11-Phase Architecture

| Phase | Layer | Components |
|:-----:|-------|------------|
| 00 | HWI Advisor | Auto hardware calibration, tuning profile |
| 00 | Foundation | Driver setup, Docker |
| 01 | Infrastructure | Portainer, WebSSH |
| 02 | Database | PostgreSQL 17, pgAdmin 4 |
| 03 | AI Interface | Ollama, OpenWebUI, Redis |
| 04 | Automation | n8n (queue mode + workers) |
| 05 | RAG Stack | Qdrant, Docling, Mosquitto |
| 06 | AI Core Engine | Lemonade inference engine |
| 07 | Validation | Health checks, benchmark scripts |
| 08 | Backup & Recovery | 1-click backup, restore, VRAM purge |
| 09 | Monitoring & Alerts | tiger-monitor, MQTT alerting |
| 10 | Observability | Grafana, Prometheus, Loki, cAdvisor |

---

## Service Ports (Default)

| Service | Port |
|---------|:----:|
| OpenWebUI | 8080 |
| n8n | 5678 |
| Grafana | 3000 |
| Portainer | 9000 |
| pgAdmin | 8000 |
| Qdrant | 6333 |
| Ollama | 11434 |
| Lemonade | 8080 |

---

## Repository Structure

```
deployments/
├── tiger-deploy.sh             # detects hardware, exports TIGER_PLATFORM
└── compose-stack/
    ├── lib/common.sh           # shared shell library
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
    ├── 08-backup-recovery/
    ├── 09-monitoring-alerting/
    ├── 10-observability-grafana/
    └── migrations/
```

---

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](./CONTRIBUTING.md) for branch naming, commit format, and PR guidelines.

Please use the [issue templates](.github/ISSUE_TEMPLATE/) to report bugs or request features.

---

## License

MIT © 2026 [TigerAI-Taiwan](https://github.com/TigerAI-Taiwan)
