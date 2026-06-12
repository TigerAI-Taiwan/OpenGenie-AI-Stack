# OpenGenie AI Deployment: Uninstallation Procedure

## Purpose
This skill covers the complete and safe teardown of the OpenGenie stack. It removes containers, project data volumes, python virtual environments, background services, and snap packages without affecting the host's Docker engine or NVIDIA drivers.
Use this when you want to uninstall the project but keep the server intact.

**Trigger phrase:** User says `"uninstall this project"`, `"remove the stack"`, or `"full purge"`.

---

## Phase 1: Stop All Running Containers
Navigate to the detected stack directory first, then stop all compose services:

```bash
cd deployments/<STACK_DIR>
sudo ./master-deploy.sh clean
```

If `master-deploy.sh clean` fails (Docker daemon is broken), force-remove containers manually:
```bash
docker ps -aq | xargs docker rm -f 2>/dev/null || true
```

---

## Phase 2: Remove Docker Volumes (Data Wipe — Scoped to This Stack Only)
This permanently deletes all database data, AI model caches, and configuration volumes **owned by this stack**. Volumes from unrelated Docker projects on the same host are NOT touched.

```bash
# From deployments/<STACK_DIR>/ — iterate every numbered module and let compose
# remove only the volumes it created (matched by its own compose project label).
for dir in [0-9][0-9]-*/; do
  [ -d "$dir" ] || continue
  ( cd "$dir" && sudo docker compose down -v 2>/dev/null || true )
done

# Belt-and-braces sweep: remove any leftover volumes still labeled as belonging
# to this stack's compose projects (label name = the module directory name).
for dir in [0-9][0-9]-*/; do
  proj="${dir%/}"
  docker volume ls --filter "label=com.docker.compose.project=${proj}" -q \
    | xargs -r docker volume rm 2>/dev/null || true
done
```

> ⚠️ This is irreversible. Only do this if a full fresh install is intended.
> 🛡️ **Safety:** Never run `docker volume ls -q | xargs docker volume rm` — that nukes volumes belonging to unrelated Docker projects on the same machine.

---

## Phase 3: Remove Background Services & Snap Packages

Remove the AI Core snap packages and background monitoring services installed by the stack:

```bash
sudo systemctl stop tiger-monitor.service 2>/dev/null || true
sudo systemctl disable tiger-monitor.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/tiger-monitor.service

sudo snap remove lemonade-server 2>/dev/null || true
sudo snap remove lemonade 2>/dev/null || true
```

---

## Phase 4: Clean Up Python Virtual Environments & Large Images

Remove the massive Docling Python environment and any dangling Docker images associated with the stack:

```bash
sudo rm -rf deployments/nvidia-compose-stack/05-rag-stack-docling-qdrant-mosquitto/.venv
sudo docker rmi ghcr.io/docling-project/docling-serve-cu128:latest 2>/dev/null || true
```

---

## Phase 5: Clean Project State Files

Reset the agent's memory so the next invocation starts from `PRISTINE`:

```bash
# $PROJECT_ROOT should already be set per 00-master-orchestrator.md §2.0.
# If not, run the locator block from there first.
rm -f "$PROJECT_ROOT/.agent-state.json"
rm -f "$PROJECT_ROOT/.agent-state.bak.json"
rm -f "$PROJECT_ROOT/deployments/nvidia-compose-stack/00-pre-flight-advisor/tiger-tuning.env"
rm -f "$PROJECT_ROOT/deployments/nvidia-compose-stack/*/.env"
```

---

**STOP and print this exact message to the user:**

---
🧹 **Uninstallation complete. The OpenGenie AI Stack has been safely removed.**

All project containers, volumes, background services, and state files are gone. Your Docker engine and NVIDIA drivers remain intact.

If you wish to reinstall later, simply say: **"start fresh installation"**
---
