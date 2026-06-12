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

## 4. Port Conflicts during App Deployment
**Symptom:** `docker compose` fails with `Bind for 0.0.0.0:8080 failed: port is already allocated` or similar.
**Recovery Strategy:**
1. Identify the rogue process occupying the port (e.g., 8080 or 5432):
   ```bash
   sudo lsof -i :8080
   sudo netstat -tulpn | grep :8080
   ```
2. **If the process is a idle/orphan/residual process:**
   Safely kill it (`sudo kill -9 <PID>`) and retry deployment.
3. **If the process is an active, existing service belonging to the user:**
   (e.g., the user already has a Postgres database, Redis, or Portainer running on that port).
   **DO NOT SILENTLY OVERRIDE OR KILL IT.** You MUST pause deployment, alert the user of the conflict, and explicitly offer them the following choices:
   - **Option A (Coexist - Port+1 Strategy):** Shift our new container's port to `Port+1` (e.g., create/modify `.env` with `PORTAINER_PORT=9001`) so both services can run simultaneously.
   - **Option B (Reuse Existing):** Do not deploy our version of the container, and instead configure the rest of our AI stack to connect to the user's existing service (by updating DB connection strings in our `.env` files).
   - **Option C (Takeover):** Ask the user if it's safe to kill the old service so our stack can occupy the default port.
4. **Wait for the user's explicit decision** before taking action and continuing with `sudo ./master-deploy.sh app`.

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
This works for every `.sh` in the project (`master-deploy.sh`, `deploy.sh`, `tiger-advisor.sh`, etc.).

> 💡 **Preventive rule for the agent:** When emitting any user-facing sudo command, default to `sudo bash <script>` form from the start. See `01-deployment-state-machine.md` §2.5.

## 6. Network Timeouts (Docker Pull Fails)
**Symptom:** `error pulling image configuration: download failed after attempts=6`
**Recovery Strategy:**
1. Network hiccups happen. Simply execute the command again. Docker will resume the layer download from where it failed.
2. `sudo ./master-deploy.sh app` is idempotent. Running it multiple times is safe.
