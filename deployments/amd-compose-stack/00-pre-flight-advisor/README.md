# TigerAI Pre-flight Advisor

## 🎯 Purpose
The Pre-flight Advisor automatically detects your hardware configuration (CPU, RAM, GPU) and generates optimized settings for all deployment scripts.

## 🚀 Usage

### Step 1: Run the Advisor (REQUIRED before first deployment)
```bash
cd deployments/amd-compose-stack/00-pre-flight-advisor/
sudo ./tiger-advisor.sh
```

### Step 2: Select Optimization Profile
You will be prompted to choose:
1. **Conservative** - Stability first, low resource overhead
2. **Balanced** - Optimized for general AI workloads (Recommended)
3. **Optimal** - Maximum performance, high concurrency

### Step 3: Deploy Services
After running the advisor, all deployment scripts will automatically use the optimized settings.

## 📊 What It Detects

- **CPU Cores**: Total number of CPU cores
- **Total RAM**: System memory in GB
- **GPU Type**: NVIDIA or AMD
- **GPU VRAM**: Video memory in MB

## 🎛️ Generated Settings

The advisor creates `tiger-tuning.env` with:

- `TIGER_OPTIMIZATION_PROFILE`: Selected profile (CONSERVATIVE/BALANCED/OPTIMAL)
- `TIGER_CPU_THREADS`: Recommended worker threads
- `TIGER_N8N_WORKERS`: n8n worker count
- `TIGER_LOG_MAX_SIZE`: Log file size limit
- `TIGER_GPU_TYPE`: Detected GPU type
- `TIGER_VRAM`: GPU memory
- `TIGER_TOTAL_RAM`: System RAM
- `TIGER_CPU_CORES`: CPU core count

## 🔄 Configuration Priority

All deploy scripts load configuration in this order:
1. Local `.env` (lowest priority)
2. Parent `../.env` (medium priority)
3. `tiger-tuning.env` (highest priority - hardware optimized)

This means hardware-optimized settings always take precedence.

## 📝 Example Workflow

```bash
# 1. Run advisor first
cd deployments/amd-compose-stack/00-pre-flight-advisor/
sudo ./tiger-advisor.sh
# Select profile: 2 (Balanced)

# 2. Deploy services - they will use optimized settings automatically
cd ../04-automation-n8n/
sudo ./deploy.sh all
# n8n will use TIGER_N8N_WORKERS from tiger-tuning.env

cd ../05-rag-stack-docling-qdrant-mosquitto/
sudo ./deploy.sh all
# Qdrant will use TIGER_CPU_THREADS for search optimization
```

## 🔧 Re-running the Advisor

You can re-run the advisor anytime to:
- Change optimization profile
- Update settings after hardware changes
- Reset to recommended values

Simply run `sudo ./tiger-advisor.sh` again and select a new profile.

## 💡 Integration Status

The following services automatically use tiger-tuning.env:
- ✅ 03-ai-interface-ollama-openwebui-redis
- ✅ 04-automation-n8n
- ✅ 05-rag-stack-docling-qdrant-mosquitto
- ✅ 09-monitoring-alerting

## 🎯 Best Practices

1. **Always run the advisor before first deployment**
2. **Use Balanced profile for most scenarios**
3. **Use Optimal only if you have dedicated hardware**
4. **Re-run after hardware upgrades**
