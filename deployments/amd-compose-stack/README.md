# TigerAI Open-AI-Stack (AMD ROCm Edition)

![Project Tier](https://img.shields.io/badge/Tier-P1_Mission_Critical-red)
![GPU](https://img.shields.io/badge/GPU-AMD_ROCm_7.1.1-red)

Enterprise AI stack optimized for AMD Instinct/RDNA hardware, featuring **ROCm 7.1.1 support** and automated Vulkan environment setup.

## 🚀 Quick Start (一鍵部署)

### 1. Initialize Optimization Profile (Mandatory)
Investigate your hardware and select a profile (**Conservative** is default).
```bash
sudo bash master-deploy.sh init
```

### 2. Base System Installation
Installs ROCm Drivers, kernel headers, Docker, and Performance Services.
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

## ⚙️ Operations & Maintenance

| Action | Command | Description |
| :--- | :--- | :--- |
| **Initialize** | `sudo bash master-deploy.sh init` | Hardware advisor & performance tuning. |
| **Check Status** | `sudo bash master-deploy.sh status` | View all running containers & services. |
| **Verify System** | `sudo bash master-deploy.sh test` | Run automated health checks (Phase 07). |
| **Backup Data** | `sudo bash master-deploy.sh backup` | Execute full system backup (Phase 08). |
| **Monitor GPU** | Access `http://localhost:3000` | Real-time VRAM/Temp/TDP (Phase 10). |
| **Stop All** | `sudo bash master-deploy.sh clean` | Stop and remove all containers. |

---

## 🌐 Service Port Matrix

| Service | Host Port | Layer |
| :--- | :--- | :--- |
| **OpenWebUI** | `8080` | Phase 03 - Chat Entry |
| **n8n** | `5678` | Phase 04 - Automation |
| **Grafana** | `3000` | Phase 10 - Observability |
| **Portainer** | `9000` | Phase 01 - Docker Admin |
| **cAdvisor** | `8088` | Phase 10 - Container Metrics |
| **WebSSH** | `2222` | Phase 01 - Remote Terminal |
| **pgAdmin** | `5433` | Phase 02 - DB Admin |

---

## 🛠️ Performance Optimization (HWI Integrated)
*   **Dynamic Tuning**: Application concurrency (n8n workers) and CPU threads (Lemonade) are automatically scaled based on your `init` profile.
*   **ROCm Tuning**: Automated setup for ROCm kernel parameters and graphics version overrides.
*   **Vulkan Core**: Lemonade engine pre-configured for Vulkan-based hardware acceleration.

## 📂 Structure
Refer to the root [SDD.md](../../SDD.md) for detailed service mappings and architectural decisions.
