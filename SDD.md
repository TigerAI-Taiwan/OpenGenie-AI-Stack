# Software Design Document — OpenGenie AI Stack

| Field | Value |
|-------|-------|
| Project | OpenGenie AI Stack |
| Version | v2.0.0 |
| Author | TigerAI Engineering |
| Last Updated | 2026-05-05 |
| Target OS | Ubuntu 22.04 / 24.04 LTS |
| Deployment | Docker Compose (standalone) |

---

## 1. Overview

OpenGenie AI Stack is a modular, self-hosted AI infrastructure framework for AMD, NVIDIA, and ARM64 hardware. It transforms a standard GPU server into a production-ready AI appliance through a structured 11-phase deployment methodology.

Each phase is independently deployable and contains its own `deploy.sh` and `docker-compose.yaml`. Stacks are located under `deployments/`:

```
deployments/
├── amd-compose-stack/      # AMD ROCm GPU
├── nvidia-compose-stack/   # NVIDIA CUDA GPU
└── arm64-compose-stack/    # ARM64 (Apple Silicon / Ampere / Jetson)
```

---

## 2. 11-Phase Architecture

| Phase | Layer | Name | Core Components |
|:------|:------|:-----|:----------------|
| **00** | Advisor | HWI Advisor | `tiger-advisor.sh` — hardware calibration, auto-tuning profile generation |
| **00** | System | Foundation | Architecture-specific driver setup (ROCm / CUDA / ARM64) |
| **01** | Infra | Infrastructure | Portainer, WebSSH — container management and remote access |
| **02** | DB | Database | PostgreSQL 17, pgAdmin 4 — hardened multi-schema persistence |
| **03** | Chat | AI Interface | Ollama, OpenWebUI (HA), Redis — interactive LLM experience |
| **04** | Auto | Automation | n8n (main + workers, queue mode) — enterprise workflow engine |
| **05** | RAG | Knowledge Base | Qdrant, Docling, Mosquitto — vector storage and document processing |
| **06** | Core | AI Core Engine | Lemonade — native high-performance inference engine |
| **07** | Test | Validation | `check-health.sh`, `benchmark-tps.sh` — automated QA and smoke tests |
| **08** | Backup | Disaster Recovery | `backup-tigerai.sh`, `restore-tigerai.sh` — 1-click backup and restore |
| **09** | Alert | Monitoring | `tiger-monitor.sh`, MQTT alert workflows — proactive health alerting |
| **10** | Ops | Observability | Grafana, Prometheus, Loki, cAdvisor, DCGM — GPU telemetry and SLA dashboards |

---

## 3. Service Port Matrix

| Phase | Service | Default Port | Notes |
|:------|:--------|:------------:|:------|
| 01 | Portainer | 9000 | Container management UI |
| 01 | WebSSH | 8888 | Browser-based terminal |
| 02 | PostgreSQL | 5432 | Internal only (not exposed to host) |
| 02 | pgAdmin | 8000 | DB admin UI |
| 03 | OpenWebUI | 8080 | LLM chat interface |
| 03 | Ollama | 11434 | Inference API (localhost only) |
| 04 | n8n | 5678 | Workflow automation UI |
| 05 | Qdrant | 6333 | Vector DB REST API |
| 05 | Docling | 5001 | Document processing API |
| 05 | Mosquitto (MQTT) | 443 | IoT/monitoring message broker |
| 10 | Grafana | 3000 | Observability dashboard |

---

## 4. Database Architecture

**PostgreSQL 17** uses a single database (`tigerai`) with schema isolation:

| Schema | Owner | Purpose |
|--------|-------|---------|
| `n8n` | adm | n8n workflow data, executions, credentials |
| `openwebui` | adm | User data, chat history, model settings |
| `public` | adm | Shared/default schema |

Schema initialization is automated by each module's `deploy.sh`.

---

## 5. Redis Architecture

Redis uses database-index isolation to prevent cross-service contamination:

| DB Index | Service | Usage |
|:--------:|---------|-------|
| 0 | n8n | BullMQ job queue, worker coordination |
| 1 | OpenWebUI | Session storage, task queue |

---

## 6. Hardware Profiles (HWI Advisor)

Run `./00-pre-flight-advisor/tiger-advisor.sh` before deploying. It auto-detects hardware and writes a tuning profile to `tiger-tuning.env`.

| Profile | CPU Threads | n8n Workers | Use Case |
|---------|:-----------:|:-----------:|---------|
| Conservative | 50% | 2 | Stability-first, shared hosts |
| Balanced | 75% | 5 | Multi-user production (default) |
| Optimal | 100% | 10 | Dedicated AI servers, heavy RAG/OCR |

---

## 7. Network

All services share a single Docker bridge network: `ai_stack_net`

- Container-to-container DNS resolution via service name
- Host access via `host.docker.internal`
- External exposure only on explicitly mapped ports (see Port Matrix)

---

## 8. Per-Stack References

For stack-specific details (driver versions, GPU runtime config, platform notes):

- AMD: `deployments/amd-compose-stack/README.md`
- NVIDIA: `deployments/nvidia-compose-stack/SDD.md`
- ARM64: `deployments/arm64-compose-stack/SDD.md`
