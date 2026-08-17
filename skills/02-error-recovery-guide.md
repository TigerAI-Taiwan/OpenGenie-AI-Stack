# OpenGenie AI Deployment: Error Recovery Guide

During the deployment of the OpenGenie AI Stack, especially in dynamic or dirty environments, you may encounter system-level errors. 
As an Autonomous Agent, you must NOT stop and ask the user for help immediately. You must attempt these self-healing recovery strategies first.

## 1. APT Lock Deadlock (`/var/lib/dpkg/lock-frontend`)
**Symptom:** `E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process XXXX`
**Recovery Strategy:**
Sometimes background update processes (`unattended-upgrades`) lock the package manager.
1. Check what is holding the lock: `lsof /var/lib/dpkg/lock-frontend`
2. Forcefully kill the apt processes:
   ```bash
   sudo killall apt apt-get dpkg unattended-upgrades || true
   ```
3. Remove the locks safely:
   ```bash
   sudo rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock
   ```
4. Reconfigure dpkg:
   ```bash
   sudo dpkg --configure -a
   ```
5. Retry your previous `apt` or `master-deploy.sh` command.

## 2. NVIDIA Driver Installation Conflicts
**Symptom:** `dpkg` errors during `nvidia-driver` installation, or `nvidia-smi` says "Failed to initialize NVML: Driver/library version mismatch".
**Recovery Strategy:**
This happens when old drivers conflict, or the `nouveau` open-source driver is aggressively holding the kernel.
1. Purge all existing NVIDIA packages:
   ```bash
   sudo apt-get purge -y '*nvidia*'
   sudo apt-get autoremove -y
   ```
2. Re-run Phase 00:
   ```bash
   sudo ./master-deploy.sh system
   ```
3. If `nouveau` is interfering, reboot the system to let the blacklist take effect, then resume.

## 3. Docker Daemon Fails to Start
**Symptom:** `Cannot connect to the Docker daemon at unix:///var/run/docker.sock.` or Phase 01 fails immediately.
**Recovery Strategy:**
1. Check the Docker service status and logs:
   ```bash
   sudo systemctl status docker
   sudo journalctl -u docker --no-pager | tail -n 20
   ```
2. Often, this is caused by a corrupted `/etc/docker/daemon.json` (e.g., misconfigured NVIDIA runtime).
3. Temporarily move the config and restart to isolate the issue:
   ```bash
   sudo mv /etc/docker/daemon.json /etc/docker/daemon.json.backup
   sudo systemctl restart docker
   ```
4. Re-run Phase 00 to let it cleanly regenerate the NVIDIA Container Toolkit config.

## 4. Port Conflicts (Pre-installation Probing & Runtime Recovery)
**Symptom:** `docker compose` fails with `Bind for 0.0.0.0:8080 failed: port is already allocated` or port conflict detected prior to deployment.
**Proactive & Reactive Strategy:**
1. **Pre-installation Check:** Before launching containers, probe all configured ports in `.env` (`8080`, `9000`, `8000`, `5432`, `5678`, `6333`, `11434`, `3000`, `5001`, etc.):
   ```bash
   sudo lsof -i :8080 || ss -tulpn | grep :8080
   ```
2. **Auto Port + 1 Strategy:**
   If a port is already occupied by a host process or service, automatically update the corresponding port variable in `.env` to **`Port + 1`** (e.g. if `8080` is in use, increment `OWUI_PORT` to `8081`).
3. Verify that the new port (`Port + 1`) is available. If `Port + 1` is also in use, continue incrementing (`Port + 2`, `Port + 3`, etc.) until an available open port is found.
4. Update `.env` with the new free port, inform the user of the re-mapped port, and proceed with deployment:
   ```bash
   sudo TIGER_PLATFORM=<platform> bash master-deploy.sh all
   ```

## 5. Script Not Executable / `command not found` / `Permission denied`
**Symptom:** Running `./master-deploy.sh system` (or any other `./xxx.sh` in the project) returns:
- `bash: ./master-deploy.sh: Permission denied`, or
- `sudo: ./master-deploy.sh: command not found`

**Cause:** Project shell scripts are tracked in git **without the executable bit** (`-rw-rw-r--`). `./script.sh` therefore fails. You must NOT `chmod +x` them (modifying project files is prohibited per `01-deployment-state-machine.md` §1).

**Recovery Strategy:**
Invoke the script via the `bash` interpreter instead of relying on the exec bit:
```bash
cd /home/<user>/OpenGenie-AI-Stack/deployments/<stack-dir>
sudo bash master-deploy.sh system     # or: init / app / clean
```
This works for every `.sh` in the project (`master-deploy.sh`, `deploy.sh`, etc.).

> 💡 **Preventive rule for the agent:** When emitting any user-facing sudo command, default to `sudo bash <script>` form from the start. See `01-deployment-state-machine.md` §2.5.

## 6. Network Timeouts (Docker Pull Fails)
**Symptom:** `error pulling image configuration: download failed after attempts=6`
**Recovery Strategy:**
1. Network hiccups happen. Simply execute the command again. Docker will resume the layer download from where it failed.
2. `sudo ./master-deploy.sh app` is idempotent. Running it multiple times is safe.

## 7. OpenWebUI Image Reference Resolution Error (`docker.io/openwebui/open-webui:main: not found`)
**Symptom:** `Error response from daemon: failed to resolve reference "docker.io/openwebui/open-webui:main": docker.io/openwebui/open-webui:main: not found`
**Cause:** Setting `OWUI_IMAGE=openwebui/open-webui:main` in `.env` causes Docker Compose to prefix `docker.io/`, but Docker Hub does not have a `:main` tag for OpenWebUI.
**Recovery Strategy:**
1. For GitHub Container Registry (GHCR): Set `OWUI_IMAGE=ghcr.io/open-webui/open-webui:main` in `.env`.
2. For Docker Hub fallback: Set `OWUI_IMAGE=openwebui/open-webui:latest` in `.env`.
3. Never use `openwebui/open-webui:main` without `ghcr.io/`.

