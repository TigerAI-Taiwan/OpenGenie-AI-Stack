# TigerAI Stack - Technical Reference Guide

## 📋 Complete Port Mapping

### External Ports (Host Access)
| Port | Service | Container | Protocol | Access Level |
|:-----|:--------|:----------|:---------|:-------------|
| 1883 | Mosquitto MQTT | mosquitto | TCP | Public |
| 2222 | WebSSH | webssh | HTTP | Admin |
| 3000 | Grafana | grafana | HTTP | Public |
| 3100 | Loki | loki | HTTP | Internal |
| 5001 | Docling | docling | HTTP | Internal |
| 5678 | n8n | n8n-main | HTTP | Public |
| 6333 | Qdrant HTTP | qdrant | HTTP | Internal |
| 6334 | Qdrant gRPC | qdrant | gRPC | Internal |
| 8000 | pgAdmin | pgadmin | HTTP | Admin |
| 8080 | OpenWebUI | openwebui-main | HTTP | Public |
| 8088 | cAdvisor | cadvisor | HTTP | Public |
| 9000 | Portainer | portainer | HTTP | Admin |
| 11434 | Ollama | ollama | HTTP | Internal |

### Internal Ports (Container-to-Container)
| Port | Service | Container | Used By |
|:-----|:--------|:----------|:--------|
| 5432 | PostgreSQL | postgres | n8n, OpenWebUI, pgAdmin |
| 6379 | Redis | redis | n8n, OpenWebUI |
| 9090 | Prometheus | prometheus | Grafana |
| 9400 | DCGM Exporter | gpu-exporter | Prometheus |

---

## 🗄️ PostgreSQL Connection Matrix

### Database: `tigerai`
| Service | Schema | Connection String | Purpose |
|:--------|:-------|:------------------|:--------|
| **n8n** | `n8n` | `postgresql://adm:password@postgres:5432/tigerai` | Workflow data, executions, credentials |
| **OpenWebUI** | `openwebui` | `postgresql://adm:password@postgres:5432/tigerai` | User data, chat history, settings |
| **pgAdmin** | - | `postgres:5432` | Database administration |

### Schema Details
```sql
-- Database: tigerai
-- User: adm
-- Schemas:
--   - n8n (owned by adm)
--   - openwebui (owned by adm)
--   - public (default)

-- Search Path Configuration (set at database level):
ALTER DATABASE tigerai SET search_path TO n8n, public;  -- For n8n connections
ALTER DATABASE tigerai SET search_path TO openwebui, public;  -- For OpenWebUI connections
```

### Connection Examples
```bash
# n8n connection test
docker exec -it postgres psql -U adm -d tigerai -c "SET search_path TO n8n; SELECT current_schema();"

# OpenWebUI connection test
docker exec -it postgres psql -U adm -d tigerai -c "SET search_path TO openwebui; SELECT current_schema();"

# List all schemas
docker exec -it postgres psql -U adm -d tigerai -c "\dn"

# List tables in n8n schema
docker exec -it postgres psql -U adm -d tigerai -c "\dt n8n.*"
```

---

## 🔴 Redis Connection Matrix

### Database Allocation
| DB | Service | Prefix | Connection String | Purpose |
|:---|:--------|:-------|:------------------|:--------|
| **0** | n8n | `n8n:` | `redis://redis:6379/0` | Job queue (Bull/BullMQ) |
| **1** | OpenWebUI | - | `redis://redis:6379/1` | Task queue, session cache |

### n8n Redis Configuration
```yaml
Environment Variables:
  QUEUE_MODE: redis
  EXECUTIONS_MODE: queue
  QUEUE_BULL_REDIS_HOST: redis
  QUEUE_BULL_REDIS_PORT: 6379
  QUEUE_BULL_REDIS_DB: 0
  QUEUE_BULL_PREFIX: n8n

Key Pattern:
  n8n:bull:*  # Job queues
  n8n:cache:* # Execution cache
```

### OpenWebUI Redis Configuration
```yaml
Environment Variables:
  REDIS_URL: redis://redis:6379/1

Key Pattern:
  task:*      # Background tasks
  session:*   # User sessions
  cache:*     # Response cache
```

### Redis Health Check
```bash
# Check Redis connectivity
docker exec -it redis redis-cli ping

# Check database info
docker exec -it redis redis-cli INFO keyspace

# Check n8n keys (DB 0)
docker exec -it redis redis-cli -n 0 KEYS "n8n:*"

# Check OpenWebUI keys (DB 1)
docker exec -it redis redis-cli -n 1 KEYS "*"

# Monitor real-time commands
docker exec -it redis redis-cli MONITOR
```

---

## 🌐 Docker Network Configuration

### Network: `ai_stack_net`
```yaml
Type: bridge
Driver: bridge
Scope: local
Subnet: Auto-assigned by Docker
Gateway: Auto-assigned by Docker
```

### Network Topology
```
ai_stack_net (external: true)
├── postgres (hostname: postgres)
├── pgadmin (hostname: pgadmin)
├── redis (hostname: redis)
├── ollama (hostname: ollama)
├── openwebui-main (hostname: openwebui-main)
├── openwebui-worker-01 (hostname: openwebui-worker-01)
├── openwebui-worker-02 (hostname: openwebui-worker-02)
├── n8n-main (hostname: n8n-main)
├── n8n-worker (hostname: n8n-worker, scalable via --scale)
├── mosquitto (hostname: mosquitto)
├── docling (hostname: docling)
├── qdrant (hostname: qdrant)
├── prometheus (hostname: prometheus)
├── grafana (hostname: grafana)
├── loki (hostname: loki)
├── cadvisor (hostname: cadvisor)
├── gpu-exporter (hostname: gpu-exporter)
├── portainer (hostname: portainer)
├── webssh (hostname: webssh)
└── cloudflare (hostname: cloudflare)
```

### DNS Resolution
All containers can resolve each other by container name or hostname:
```bash
# From any container, you can access:
postgres:5432
redis:6379
ollama:11434
qdrant:6333
# etc.
```

### Host Access Configuration
All containers have `extra_hosts` configured:
```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

This allows containers to access host services via `host.docker.internal`.

### Network Commands
```bash
# Inspect network
docker network inspect ai_stack_net

# List all containers on network
docker network inspect ai_stack_net --format '{{range .Containers}}{{.Name}} {{end}}'

# Create network (if not exists)
docker network create ai_stack_net

# Remove network (WARNING: stops all services)
docker network rm ai_stack_net
```

---

## 🚀 Service Startup Order & Dependencies

### Critical Path (Must Follow Order)

#### **Phase 1: Foundation** (No Dependencies)
```bash
# 1.1 Network Creation
docker network create ai_stack_net

# 1.2 Infrastructure (Optional)
cd 01-infra-webssh-portainer
./deploy.sh
```

#### **Phase 2: Data Layer** (Depends on: Network)
```bash
# 2.1 PostgreSQL (CRITICAL - Required by n8n, OpenWebUI)
cd 02-database-postgres-pgadmin
./deploy.sh all

# Wait for PostgreSQL to be ready
docker exec -it postgres pg_isready -U adm

# 2.2 Redis (CRITICAL - Required by n8n, OpenWebUI)
cd 03-ai-interface-ollama-openwebui-redis
docker compose up -d redis

# Wait for Redis to be ready
docker exec -it redis redis-cli ping
```

#### **Phase 3: AI Services** (Depends on: PostgreSQL, Redis)
```bash
# 3.1 Ollama (Required by OpenWebUI)
cd 03-ai-interface-ollama-openwebui-redis
docker compose up -d ollama

# 3.2 OpenWebUI (Depends on: PostgreSQL, Redis, Ollama)
docker compose up -d openwebui-main openwebui-worker-01 openwebui-worker-02

# OR deploy entire stack
./deploy.sh all
```

#### **Phase 4: Automation** (Depends on: PostgreSQL, Redis from Phase 2)
```bash
# 4.1 n8n (Depends on: PostgreSQL, Redis)
cd 04-automation-n8n
./deploy.sh all

# IMPORTANT: Redis must be running BEFORE n8n starts
# Redis is in stack 03, so deploy 03 before 04
```

#### **Phase 5: RAG Stack** (Independent, but Qdrant benefits from GPU)
```bash
# 5.1 Mosquitto (Independent)
cd 05-rag-stack-docling-qdrant-mosquitto
docker compose up -d mosquitto

# 5.2 Qdrant (Independent)
docker compose up -d qdrant

# 5.3 Docling (Optional - may fail on incompatible CPUs)
docker compose up -d docling
# OR skip if CPU incompatible
```

#### **Phase 6: Monitoring** (Can start anytime, monitors all services)
```bash
# 6.1 Observability Stack
cd 10-observability-grafana
./deploy.sh

# Services start in order:
# - Prometheus (collects metrics)
# - GPU Exporter (exports GPU metrics)
# - cAdvisor (exports container metrics)
# - Loki (log aggregation)
# - Grafana (visualization, depends on Prometheus & Loki)
```

### Dependency Graph
```
Network (ai_stack_net)
  ├─> PostgreSQL
  │     ├─> n8n (main + workers)
  │     └─> OpenWebUI (main + workers)
  │
  ├─> Redis
  │     ├─> n8n (queue)
  │     └─> OpenWebUI (cache)
  │
  ├─> Ollama
  │     └─> OpenWebUI (LLM inference)
  │
  ├─> Mosquitto (independent)
  ├─> Qdrant (independent)
  ├─> Docling (independent)
  │
  ├─> Prometheus
  │     ├─> GPU Exporter
  │     ├─> cAdvisor
  │     └─> Grafana
  │
  └─> Loki
        └─> Grafana
```

### Startup Verification
```bash
# Check all critical services are running
docker ps --filter "name=postgres" --filter "name=redis" --filter "name=n8n" --filter "name=openwebui"

# Check PostgreSQL is ready
docker exec -it postgres pg_isready -U adm

# Check Redis is ready
docker exec -it redis redis-cli ping

# Check n8n can connect to Redis
docker logs n8n-main | grep -i redis

# Check OpenWebUI can connect to database
docker logs openwebui-main | grep -i database
```

---

## 📁 Directory & Volume Structure

### Host Directory Paths

#### **Configuration Directories**
```
/opt/tigerai/                           # Base directory
├── docling/                            # Docling data
├── qdrant/                             # Qdrant vector storage
├── mosquitto/                          # Mosquitto MQTT
│   ├── config/
│   │   └── mosquitto.conf
│   ├── data/
│   └── log/
└── (other service data as needed)
```

#### **Project Structure**
```
/c/Tools/@@@@@@Antigravity/nvidia-compose-stack/
├── .env                                # Global environment variables
├── README.md                           # User documentation
├── SDD.md                              # Technical documentation
├── master-deploy.sh                    # Master deployment script
│
├── 00-pre-flight-advisor/              # Hardware detection
│   └── deploy.sh
│
├── 00-system-setup-nvidia-docker/      # NVIDIA driver setup
│   └── deploy.sh
│
├── 01-infra-webssh-portainer/          # Infrastructure
│   ├── .env
│   ├── docker-compose.yaml
│   └── deploy.sh
│
├── 02-database-postgres-pgadmin/       # Database layer
│   ├── .env
│   ├── docker-compose.yaml
│   └── deploy.sh
│
├── 03-ai-interface-ollama-openwebui-redis/  # AI interface
│   ├── .env
│   ├── docker-compose.yaml
│   └── deploy.sh
│
├── 04-automation-n8n/                  # Automation
│   ├── .env
│   ├── docker-compose.yaml
│   └── deploy.sh
│
├── 05-rag-stack-docling-qdrant-mosquitto/  # RAG stack
│   ├── .env
│   ├── docker-compose.yaml
│   └── deploy.sh
│
├── 06-ai-core-lemonade/                # AI core engine
│   └── deploy.sh
│
└── 10-observability-grafana/           # Monitoring
    ├── .env
    ├── docker-compose.yaml
    ├── deploy.sh
    ├── prometheus/
    │   └── prometheus.yml
    └── grafana/
        └── provisioning/
            ├── datasources/
            │   └── datasources.yml
            └── dashboards/
                ├── dashboards.yml
                ├── docker-containers.json
                └── nvidia-gpu.json
```

### Docker Volumes

#### **Named Volumes**
```bash
# List all volumes
docker volume ls

# Volume details
docker volume inspect <volume_name>
```

| Volume Name | Service | Mount Point | Purpose |
|:------------|:--------|:------------|:--------|
| `prometheus_data` | Prometheus | `/prometheus` | Metrics storage |
| `grafana_data` | Grafana | `/var/lib/grafana` | Dashboard configs |
| `postgres_data` | PostgreSQL | `/var/lib/postgresql/data` | Database files |
| `redis_data` | Redis | `/data` | Cache persistence |
| `n8n_data` | n8n | `/home/node/.n8n` | Workflow data |
| `n8n_files` | n8n | `/home/node/.n8n-files` | File storage |
| `qdrant_data` | Qdrant | `/qdrant/storage` | Vector storage |
| `ollama_data` | Ollama | `/root/.ollama` | Model storage |
| `openwebui_data` | OpenWebUI | `/app/backend/data` | User data |

#### **Bind Mounts**
| Host Path | Container Path | Service | Purpose |
|:----------|:---------------|:--------|:--------|
| `./prometheus/prometheus.yml` | `/etc/prometheus/prometheus.yml` | Prometheus | Config file |
| `./grafana/provisioning` | `/etc/grafana/provisioning` | Grafana | Auto-provisioning |
| `/opt/tigerai/docling` | `/app/data` | Docling | Document storage |
| `/opt/tigerai/qdrant` | `/qdrant/storage` | Qdrant | Vector DB |
| `/opt/tigerai/mosquitto/config` | `/mosquitto/config` | Mosquitto | MQTT config |
| `/opt/tigerai/mosquitto/data` | `/mosquitto/data` | Mosquitto | MQTT data |
| `/opt/tigerai/mosquitto/log` | `/mosquitto/log` | Mosquitto | MQTT logs |
| `/var/run/docker.sock` | `/var/run/docker.sock` | cAdvisor, Portainer | Docker API |

### Volume Management Commands
```bash
# Backup a volume
docker run --rm -v <volume_name>:/data -v $(pwd):/backup alpine tar czf /backup/<volume_name>_$(date +%Y%m%d).tar.gz /data

# Restore a volume
docker run --rm -v <volume_name>:/data -v $(pwd):/backup alpine tar xzf /backup/<backup_file>.tar.gz -C /

# Remove unused volumes (DANGEROUS)
docker volume prune

# Remove specific volume (DANGEROUS - data loss)
docker volume rm <volume_name>
```

---

## ⚠️ Critical Startup Notes

### 1. **Redis Must Start Before n8n**
```bash
# CORRECT ORDER:
cd 03-ai-interface-ollama-openwebui-redis
./deploy.sh all  # This starts Redis

# Wait for Redis
docker exec -it redis redis-cli ping

# Then start n8n
cd 04-automation-n8n
./deploy.sh all
```

### 2. **PostgreSQL Schema Initialization**
```bash
# Schemas are auto-created by deploy scripts
# But you can verify:
docker exec -it postgres psql -U adm -d tigerai -c "\dn"

# Expected output:
#   List of schemas
#   Name     |  Owner
# -----------+----------
#  n8n       | adm
#  openwebui | adm
#  public    | postgres
```

### 3. **GPU Services Require NVIDIA Runtime**
```bash
# Verify NVIDIA runtime is available
docker info | grep -i nvidia

# Test GPU access
docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi
```

### 4. **Network Must Exist Before Any Service**
```bash
# Create network if not exists
docker network create ai_stack_net

# Verify
docker network ls | grep ai_stack_net
```

### 5. **Docling CPU Compatibility**
```bash
# Check CPU flags
cat /proc/cpuinfo | grep flags | head -1

# Required for Docling:
# - sse4_2
# - popcnt
# - ssse3

# If missing, skip Docling:
cd 05-rag-stack-docling-qdrant-mosquitto
docker compose up -d mosquitto qdrant
# Skip: docker compose up -d docling
```

---

## 🔍 Troubleshooting Quick Reference

### Service Won't Start
```bash
# Check logs
docker logs <container_name> --tail 100 -f

# Check dependencies
docker ps --filter "name=postgres" --filter "name=redis"

# Restart service
docker compose restart <service_name>
```

### Database Connection Issues
```bash
# Test PostgreSQL
docker exec -it postgres psql -U adm -d tigerai -c "SELECT version();"

# Check schema
docker exec -it postgres psql -U adm -d tigerai -c "\dn"

# Check connections
docker exec -it postgres psql -U adm -d tigerai -c "SELECT * FROM pg_stat_activity;"
```

### Redis Connection Issues
```bash
# Test Redis
docker exec -it redis redis-cli ping

# Check databases
docker exec -it redis redis-cli INFO keyspace

# Monitor connections
docker exec -it redis redis-cli CLIENT LIST
```

### Network Issues
```bash
# Test DNS resolution
docker exec -it <container> ping postgres
docker exec -it <container> ping redis

# Check network connectivity
docker network inspect ai_stack_net
```

---

**Last Updated**: 2026-02-11  
**Version**: 1.0.0  
**Maintained by**: TigerAI Team
