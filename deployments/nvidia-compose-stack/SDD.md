# Software Design Document (SDD) - TigerAI Open-AI-Stack (NVIDIA)

## 📝 Document Metadata
*   **Project Name:** Open-AI-Stack (NVIDIA CUDA Edition)
*   **Tier:** P1 (Mission Critical Infrastructure)
*   **Version:** v2.0.0 (Production Deployment)
*   **Target Hardware:** NVIDIA RTX 5090 / 4090 / Data Center GPUs
*   **Software Stack:** CUDA 12.x, NVIDIA Driver 580+, NVIDIA Container Toolkit
*   **Last Updated:** 2026-02-11
*   **Status:** Production Ready

---

## A. Functional & Business Requirements (功能需求)

### 1. Core Objectives
To provide an enterprise-grade AI infrastructure on Ubuntu 24.04 LTS optimized for NVIDIA GPUs using Docker Compose and native system services, with comprehensive monitoring, automation, and RAG capabilities.

### 2. Architecture Overview
Modular microservices architecture utilizing NVIDIA Docker Runtimes and CUDA-optimized inference engines, with complete observability.

### 3. Service Layer Breakdown

| Layer ID | Module Name | Core Services | NVIDIA Specifics | Status |
|:---------|:------------|:--------------|:-----------------|:-------|
| **00** | System Foundation | Driver 580, Docker, Persistenced | PPA-based driver install, Persistence Daemon | ✅ |
| **01** | Infrastructure | WebSSH, Portainer, Cloudflare | Standard admin tools | ✅ |
| **02** | Database | PostgreSQL 17, pgAdmin 4 | Schema isolation (n8n, openwebui) | ✅ |
| **03** | AI Interface | Ollama, Redis, OpenWebUI (1+2) | `nvidia` runtime, GPU acceleration | ✅ |
| **04** | Automation | n8n Main + 2 Workers | Queue mode with Redis, N8N_SECURE_COOKIE | ✅ |
| **05** | RAG Stack | Mosquitto, Docling, Qdrant | GPU-accelerated vector search | ⚠️ |
| **06** | AI Core | Lemonade (Core) | `--llamacpp cuda` and `CUDA_VISIBLE_DEVICES` | ✅ |
| **10** | Observability | Grafana, Prometheus, Loki, cAdvisor, DCGM | Complete monitoring stack | ✅ |

---

## B. Technical Architecture

### 1. Network Architecture
**Shared Network**: `ai_stack_net` (external, bridge mode)
- All services communicate via this network
- DNS resolution between containers
- Host access via `host.docker.internal`

### 2. Database Architecture

#### **PostgreSQL Configuration**
- **Database**: `tigerai`
- **User**: `adm`
- **Schemas**:
  - `n8n` - n8n workflow data
  - `openwebui` - OpenWebUI user data and settings
- **Search Path**: Set at database level for each schema
- **Connection Strings**:
  ```
  n8n: postgresql://adm:password@postgres:5432/tigerai
  openwebui: postgresql://adm:password@postgres:5432/tigerai
  ```

#### **Schema Initialization**
- Automated via `deploy.sh` scripts
- `init_schemas` function in 02-database
- `check_db_schema` function in 03 and 04 stacks

### 3. Redis Architecture

#### **Database Isolation**
- **DB 0**: n8n (with prefix `n8n:`)
  - Queue: Bull/BullMQ
  - Workers: 2 concurrent workers
  - Execution mode: queue
- **DB 1**: OpenWebUI
  - Task queue
  - Session storage

#### **Health Check**
```yaml
healthcheck:
  test: ["CMD", "redis-cli", "ping"]
  interval: 5s
  timeout: 3s
  retries: 5
```

### 4. n8n Configuration

#### **Architecture**
- **Main Instance**: Web UI + API (Port 5678)
- **Worker 01**: Background execution
- **Worker 02**: Background execution

#### **Key Settings**
```yaml
QUEUE_MODE: redis
EXECUTIONS_MODE: queue
QUEUE_BULL_REDIS_HOST: redis
QUEUE_BULL_REDIS_DB: 0
QUEUE_BULL_PREFIX: n8n
N8N_SECURE_COOKIE: false  # For reverse proxy compatibility
OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS: true
```

#### **Security Consideration**
`N8N_SECURE_COOKIE=false` allows:
- Cookie transmission over HTTP
- Proper operation behind reverse proxies
- Compatibility with Cloudflare tunnels

### 5. OpenWebUI Configuration

#### **Architecture**
- **Main Instance**: Web UI (Port 8080)
- **Worker 01**: Background tasks
- **Worker 02**: Background tasks

#### **Key Settings**
```yaml
DATABASE_URL: postgresql://adm:password@postgres:5432/tigerai
REDIS_URL: redis://redis:6379/1
WEBUI_SECRET_KEY: CHANGE_ME
```

### 6. RAG Stack Configuration

#### **Mosquitto (MQTT Broker)**
- Port: 1883
- Anonymous access enabled
- Persistence enabled

#### **Qdrant (Vector Database)**
- Image: `qdrant/qdrant:gpu-nvidia-latest`
- GPU Indexing: Enabled
- Performance tuning:
  ```yaml
  QDRANT__STORAGE__PERFORMANCE__MAX_SEARCH_THREADS: 40
  QDRANT__STORAGE__PERFORMANCE__OPTIMIZER_MAX_THREADS: 4
  QDRANT__GPU__INDEXING: 1
  ```

#### **Docling (Document Processing)**
- **Status**: ⚠️ Requires x86-64-v2 CPU support
- **Issue**: KVM virtual machines with "Common KVM processor" lack required instruction sets
- **Workaround**: 
  1. Modify KVM CPU model to `host-passthrough`
  2. Or disable Docling temporarily
- **Required Instructions**: SSE4.2, POPCNT, SSSE3

### 7. Observability Stack

#### **Prometheus Configuration**
```yaml
scrape_configs:
  - job_name: 'prometheus'
  - job_name: 'gpu-metrics' (DCGM Exporter)
  - job_name: 'cadvisor'
```

#### **Grafana Configuration**
- **Port**: 3000
- **Credentials**: admin / CHANGE_ME
- **Data Sources**:
  - Prometheus (default)
  - Loki (logs)
- **Dashboards**:
  - Docker Containers Overview
  - NVIDIA GPU Monitoring

#### **DCGM Exporter**
- Exports NVIDIA GPU metrics to Prometheus
- Metrics include:
  - GPU utilization
  - Memory usage
  - Temperature
  - Power consumption

#### **cAdvisor**
- **Port**: 8088 (external), 8080 (internal)
- Monitors container resource usage
- Metrics: CPU, memory, network, disk I/O

#### **Loki**
- **Port**: 3100
- Log aggregation service
- Integrated with Grafana

---

## C. Security & Performance (資安與效能)

### 1. Security Measures

#### **Authentication**
- **Grafana**: Basic Auth (admin / CHANGE_ME)
- **PostgreSQL**: Password-based (adm / from .env)
- **Other Services**: Behind reverse proxy (Cloudflare)

#### **Network Isolation**
- All services on isolated `ai_stack_net`
- No direct external exposure (except via reverse proxy)
- Container-to-container communication only

#### **Secret Management**
- Environment variables in `.env` files
- Stable keys for n8n and OpenWebUI
- Database credentials centralized

### 2. Performance Optimization

#### **NVIDIA GPU**
- **Persistence Daemon**: Prevents GPU sleep/throttling
- **Runtime Isolation**: `nvidia-container-toolkit`
- **GPU Allocation**: 
  - Ollama: All GPUs
  - Qdrant: All GPUs (when supported)
  - DCGM Exporter: All GPUs

#### **CPU Optimization**
- **Qdrant**: 40 search threads (Xeon optimization)
- **n8n Workers**: 2 concurrent workers
- **OpenWebUI Workers**: 2 concurrent workers

#### **Memory Management**
- **Shared Memory**: 16GB for Docling
- **Shared Memory**: 1GB for n8n

#### **Logging**
- **Max Size**: 50MB per log file
- **Max Files**: 3 rotations
- **Driver**: json-file

---

## D. Data Flow & Integration

### 1. User Request Flow
```
User → OpenWebUI (8080) → Ollama (11434) → GPU Inference → Response
                      ↓
                   Redis (Cache)
                      ↓
                PostgreSQL (History)
```

### 2. Automation Flow
```
n8n Main (5678) → Redis Queue → n8n Workers → External APIs
                                            ↓
                                      PostgreSQL (Workflow Data)
```

### 3. RAG Flow
```
Document → Docling (5001) → Processing → Qdrant (6333) → Vector Storage
                                                        ↓
                                                   GPU Indexing
```

### 4. Monitoring Flow
```
Services → Prometheus (9090) → Grafana (3000) → Dashboards
        ↓
    DCGM Exporter → GPU Metrics
        ↓
    cAdvisor → Container Metrics
        ↓
    Loki → Log Aggregation
```

---

## E. Deployment & Operations

### 1. Deployment Sequence
```bash
# 1. System Foundation
00-system-setup-nvidia-docker/deploy.sh

# 2. Infrastructure
01-infra-webssh-portainer/deploy.sh

# 3. Database
02-database-postgres-pgadmin/deploy.sh all

# 4. AI Interface
03-ai-interface-ollama-openwebui-redis/deploy.sh all

# 5. Automation
04-automation-n8n/deploy.sh all

# 6. RAG Stack (partial - skip Docling if CPU incompatible)
05-rag-stack-docling-qdrant-mosquitto/deploy.sh
docker compose up -d qdrant mosquitto

# 7. Observability
10-observability-grafana/deploy.sh
```

### 2. Health Checks

#### **Database**
```bash
docker exec -it postgres psql -U adm -d tigerai -c "\dn"
```

#### **Redis**
```bash
docker exec -it redis redis-cli ping
docker exec -it redis redis-cli INFO
```

#### **GPU**
```bash
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi
```

#### **Services**
```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

### 3. Backup Strategy

#### **Database Backup**
```bash
docker exec postgres pg_dump -U adm tigerai > backup_$(date +%Y%m%d).sql
```

#### **Volume Backup**
```bash
docker run --rm -v prometheus_data:/data -v $(pwd):/backup alpine tar czf /backup/prometheus_$(date +%Y%m%d).tar.gz /data
```

### 4. Troubleshooting

#### **Common Issues**

1. **Docling Fails to Start**
   - **Symptom**: `Fatal glibc error: CPU does not support x86-64-v2`
   - **Cause**: KVM virtual machine CPU model
   - **Solution**: Modify VM CPU to `host-passthrough` or disable Docling

2. **n8n Cannot Connect to Redis**
   - **Symptom**: Connection refused errors
   - **Cause**: Redis not started before n8n
   - **Solution**: Ensure 03-ai-interface is deployed before 04-automation

3. **Grafana No Data**
   - **Symptom**: Empty dashboards
   - **Cause**: Data sources not configured or no metrics
   - **Solution**: Check Prometheus targets, import dashboards

---

## F. Known Limitations & Future Enhancements

### Current Limitations
1. **Docling**: Requires x86-64-v2 CPU (incompatible with basic KVM CPU models)
2. **Grafana Dashboards**: Require manual import or creation

### Planned Enhancements
1. **Auto-scaling**: Dynamic worker scaling based on load
2. **High Availability**: Multi-node deployment support
3. **Advanced Monitoring**: Custom alerting rules
4. **Backup Automation**: Scheduled backup with retention policies
5. **SSL/TLS**: Internal service encryption

---

## G. Configuration Reference

### Environment Variables Summary

#### **Global (.env in root)**
```bash
OWUI_PORT=8080
N8N_PORT=5678
GRAFANA_PORT=3000
```

#### **Database (02-database/.env)**
```bash
PG_IMAGE=postgres:17
PG_USER=adm
PG_DB=tigerai
```

#### **n8n (04-automation/.env)**
```bash
N8N_IMAGE=docker.n8n.io/n8nio/n8n:latest
N8N_SECRET=CHANGE_ME
REDIS_HOST=redis
DB_POSTGRESDB_SCHEMA=n8n
```

#### **RAG Stack (05-rag-stack/.env)**
```bash
DOCLING_IMAGE=ghcr.io/docling-project/docling-serve:latest
QDRANT_IMAGE=qdrant/qdrant:gpu-nvidia-latest
QDRANT_MAX_THREADS=40
```

#### **Observability (10-observability/.env)**
```bash
GRAFANA_IMAGE=grafana/grafana-oss:latest
PROMETHEUS_IMAGE=prom/prometheus:latest
DCGM_EXPORTER_IMAGE=nvidia/dcgm-exporter:latest
```

---

## H. Maintenance Procedures

### Daily Operations
- Check Grafana dashboards for anomalies
- Review container logs for errors

### Weekly Tasks
- Review disk usage and clean old logs
- Check for security updates
- Verify backup integrity

### Monthly Tasks
- Review and optimize resource allocation
- Audit access logs and security settings

---

## I. Appendix

### A. Port Reference
| Port | Service | Protocol | Access |
|:-----|:--------|:---------|:-------|
| 1883 | Mosquitto | MQTT | Internal |
| 3000 | Grafana | HTTP | External |
| 3100 | Loki | HTTP | Internal |
| 5001 | Docling | HTTP | Internal |
| 5432 | PostgreSQL | TCP | Internal |
| 5678 | n8n | HTTP | External |
| 6333 | Qdrant | HTTP | Internal |
| 6334 | Qdrant | gRPC | Internal |
| 6379 | Redis | TCP | Internal |
| 8000 | pgAdmin | HTTP | External |
| 8080 | OpenWebUI | HTTP | External |
| 8088 | cAdvisor | HTTP | External |
| 9000 | Portainer | HTTP | External |
| 9090 | Prometheus | HTTP | Internal |
| 11434 | Ollama | HTTP | Internal |

### B. Volume Reference
| Volume | Service | Purpose |
|:-------|:--------|:--------|
| `prometheus_data` | Prometheus | Metrics storage |
| `grafana_data` | Grafana | Dashboard configs |
| `postgres_data` | PostgreSQL | Database files |
| `redis_data` | Redis | Cache persistence |
| `n8n_data` | n8n | Workflow data |
| `qdrant_data` | Qdrant | Vector storage |

### C. Useful Commands
```bash
# View all containers
docker ps -a

# View logs
docker logs <container> -f --tail 100

# Restart service
docker compose restart <service>

# Update image
docker compose pull <service>
docker compose up -d <service>

# Clean system
docker system prune -a --volumes

# Export/Import database
docker exec postgres pg_dump -U adm tigerai > backup.sql
docker exec -i postgres psql -U adm tigerai < backup.sql
```

---

**Document Version**: 2.0.0  
**Last Review**: 2026-02-11  
**Next Review**: 2026-03-11  
**Maintained by**: TigerAI Team
