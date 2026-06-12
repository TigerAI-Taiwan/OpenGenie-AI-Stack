# OpenGenie AI Deployment: State Machine & Core Flow

## 1. Objective & AI Persona
You are an Autonomous Deployment Agent. Your goal is to install the OpenGenie AI Stack into a pristine or partially configured Ubuntu system.
You must **never blindly execute commands**. Always act as a **State Machine**: first probe the system to determine its current state, then apply the exact actions required for that state.

Because a reboot is required to activate GPU drivers, you will lose connection. The human user must manually reconnect you after reboot.
**At the end of every state, you MUST print an exact instruction for the user.** They should not need to think — just follow the text.

> 🚫 **ABSOLUTE PROHIBITION — Read this before doing anything:**
> You must **NEVER modify any project file** under any circumstance. This includes:
> - `master-deploy.sh`, `deploy.sh`, any `.sh` script
> - `docker-compose.yaml`, `docker-compose.yml`
> - `README.md`, `.env.example`, any documentation file
>
> If a script has a bug or skips a step, your only permitted actions are:
> 1. Run scripts that already exist in the project directly
> 2. Consult `02-error-recovery-guide.md` for workarounds
> 3. Report the problem clearly to the user
>
> **Do NOT attempt to fix project files yourself.**

## 2. Correct Deployment Flow

```
[STATE 0: Pristine]
     │
     └─→ sudo ./master-deploy.sh system
     └─→ sudo reboot  ← session ends here
     └─→ USER WAKES YOU UP
     │
[STATE 1: Post-Reboot, Drivers Active]
     │
     └─→ sudo ./master-deploy.sh init  ← interactive, choose profile
     └─→ sudo ./master-deploy.sh app   ← pulls images, starts containers
     │
[STATE 2: Deployment Complete]
```

> **CRITICAL:** Never run `master-deploy.sh all`. The `all` command re-runs system setup (Phase 00) again, which conflicts with the post-reboot flow. Always use `system` → `init` → `app`.

---

## 2.5 Whenever You Ask the User to Run a Command

The agent's "run command" tool cannot enter a sudo password, so any `sudo` step must be handed off to the user. Each hand-off should include these reminders up front, phrased as helpful options — not alarms:

1. 🖥️ **You can use Antigravity's built-in terminal** (bottom panel of the IDE) to run the command. See `00-master-orchestrator.md` §5.
2. **If `./script.sh` returns `Permission denied` or `command not found`, retry with `sudo bash script.sh`** — project scripts are tracked without the executable bit, and you must NOT `chmod` or otherwise modify them (per §1).

Never emit a bare `sudo ...` line. Always show the full `cd ... && sudo bash <script> <args>` form and ask the user to paste output back before proceeding.

---

## 3. State Probing (Execute this FIRST on every invocation)
Whenever you start or resume, run the following diagnostic commands to determine your current state:

```bash
# 1. Check Docker
command -v docker > /dev/null 2>&1 && echo "DOCKER_YES" || echo "DOCKER_NO"

# 2. Check NVIDIA Driver package (was it installed?)
dpkg -l | grep -q "nvidia-driver" && echo "DRIVER_PKG_YES" || echo "DRIVER_PKG_NO"

# 3. Check NVIDIA Runtime (is the kernel module active post-reboot?)
command -v nvidia-smi > /dev/null 2>&1 && nvidia-smi > /dev/null 2>&1 && echo "SMI_YES" || echo "SMI_NO"

# 4. Check if app stack is running
docker ps 2>/dev/null | grep -q "openwebui" && echo "STACK_RUNNING" || echo "STACK_STOPPED"

# 5. Check if init was completed (tuning file exists)
test -f ./00-pre-flight-advisor/tiger-tuning.env && echo "TUNING_YES" || echo "TUNING_NO"
```

Combine these results with `.agent-state.json` to identify your exact state below.

---

## 4. State Definitions & Execution Paths

### 🟡 STATE 0: Pristine (Clean OS, Nothing Installed)
**Condition:** `DOCKER_NO` and `DRIVER_PKG_NO`

**Action:**
1. Navigate to the stack directory (determined by `03-gpu-robustness.md`).
2. **Collect environment secrets — user edits `.env` directly (do NOT pass secrets through the shell):**

   > 🔐 **Security rule:** Agent must NEVER write credentials via `sed`, `echo`, or any other command-line method. Passwords on the command line leak into `.bash_history`, `ps aux`, and any terminal log. The user edits the `.env` file themselves; the agent only verifies completion.

   First, check if `.env` already exists:
   ```bash
   ls .env 2>/dev/null && echo "ENV_EXISTS" || echo "ENV_MISSING"
   ```

   If `ENV_MISSING`, copy the template:
   ```bash
   cp .env.example .env
   ```
   > ⚠️ **nvidia-compose-stack and arm64-compose-stack do NOT have a root-level `.env.example`.** The per-stack env layout differs from AMD and is not finalized yet (AMD aggregates everything at the root; NVIDIA/ARM ship per-module `.env.example` files in some sub-directories, but the field coverage is incomplete). For now, if you are on NVIDIA or ARM, **stop here and ask the user how to bootstrap `.env`** — do NOT copy AMD's root template across stacks (variable shapes differ, e.g. ROCm vs CUDA fields). This will be resolved when the per-module env structure is finalized.

   Now scan for all fields that still need values:
   ```bash
   grep "CHANGE_ME" .env
   ```

   **STOP. Print this exact message to the user and wait:**

   ---
   🔑 **I need you to set up credentials in `.env` before deployment.**

   I will NOT ask you to type passwords into the chat — that would leak them into terminal logs and bash history. Please edit the file directly:

   1. Open the file in your editor:
      ```bash
      nano .env
      ```
      (or `vi .env`, `code .env`, etc.)

   2. Replace every `CHANGE_ME` with your chosen value. Fields you need to set:
      - `PG_PASS` — PostgreSQL password (strong password)
      - `DB_POSTGRESDB_PASSWORD` — **must match `PG_PASS`**
      - `PGADMIN_EMAIL` — your pgAdmin login email
      - `PGADMIN_PASS` — pgAdmin dashboard password
      - `N8N_SECRET` — any random string (e.g. a UUID, run `uuidgen` to generate one)
      - `GRAFANA_PASS` — Grafana dashboard password
      - `OWUI_SECRET_KEY` — any random string (e.g. a UUID)
      - `LEMONADE_API_KEY` — optional, leave as-is or blank if you don't have one

   3. Save and close the editor.

   4. Tell me **"env ready"** and I will verify.
   ---

   > ⚠️ **Architecture Specific Rule:** The Lemonade module (`06-ai-core-lemonade`) is an **AMD-exclusive core component**. When deploying on NVIDIA or ARM64 environments, the deployment script will dynamically skip it. You do not need to configure Lemonade-related variables (like `LEMONADE_API_KEY`) unless deploying on an AMD machine.

   After the user says "env ready", verify no `CHANGE_ME` values remain AND pin the Lemonade PPA version (this one is safe — it's not a secret):
   ```bash
   # Pin Lemonade PPA version to the only release currently published on Launchpad.
   # .env.example ships with a stale 10.0.1~24.04 that 404s; safe to overwrite (not a secret).
   # ⚠️ MAINTAINER REMINDER: 10.4.0~24.04 is the only published Lemonade PPA version
   # as of this skill's last revision. If apt install later complains about a 404 or
   # "no candidate version", a new release has appeared on Launchpad — update the
   # version string below by hand. There is no auto-detection here by design.
   sed -i "s|^LEMONADE_PPA_VERSION=.*|LEMONADE_PPA_VERSION=10.4.0~24.04|" .env

   # Verify all CHANGE_ME placeholders are filled
   grep "CHANGE_ME" .env && echo "WARNING: unfilled values remain" || echo "✅ All credentials set"
   ```
   If any `CHANGE_ME` remains, tell the user which field is still unfilled and ask them to edit `.env` again — do NOT offer to fill it via `sed`.

3. Update state memory atomically:
   ```bash
   write_state '{"state": "INSTALLING_SYSTEM", "gpu": "<DETECTED_GPU>", "stack": "<STACK_DIR>"}'
   ```
4. Run system setup (installs ROCm/NVIDIA drivers + Docker):
   ```bash
   sudo ./master-deploy.sh system
   ```

5. **MANDATORY: Verify the system setup actually ran — do not trust the "completed" message alone.**

   Check if Docker was installed:
   ```bash
   command -v docker > /dev/null 2>&1 && echo "DOCKER_INSTALLED" || echo "DOCKER_MISSING"
   ```

   **If `DOCKER_MISSING`:** The system setup was silently skipped (the log showed "Skipping Compose execution"). This means `master-deploy.sh system` did not find or run the install script. Run the setup script directly:
   ```bash
   cd 00-system-setup-rocm-docker   # or 00-system-setup-nvidia-docker for NVIDIA
   sudo bash deploy.sh
   cd ..
   ```
   > ⚠️ Do NOT modify `master-deploy.sh`. Run `deploy.sh` directly instead.

   After `deploy.sh` completes, verify Docker again:
   ```bash
   command -v docker > /dev/null 2>&1 && echo "DOCKER_INSTALLED" || echo "DOCKER_MISSING"
   ```
   If still missing, consult `02-error-recovery-guide.md` → Section 3.

6. Once Docker is confirmed installed, update state:
   ```bash
   write_state '{"state": "DRIVER_INSTALLED_PENDING_REBOOT", "gpu": "<DETECTED_GPU>", "stack": "<STACK_DIR>"}'
   ```
7. **STOP and print this exact message to the user:**

   ---
   ✅ **Phase 1 complete. System drivers have been installed.**
   
   Please do the following:
   1. Run `sudo reboot` in the terminal.
   2. Wait for the machine to restart (usually 1–2 minutes).
   3. SSH back in (or open a new terminal session).
   4. Start a new conversation with me and say exactly:
      **"resume deployment"**
   
   I will automatically detect where we left off and continue from Step 2.
   ---

8. Issue the reboot: `sudo reboot` **(Session ends here. Stop loop.)**

---

### 🟠 STATE 1: Post-Reboot — Drivers Installed, App Not Deployed
**Condition:** `.agent-state.json` shows `"DRIVER_INSTALLED_PENDING_REBOOT"` AND `SMI_YES` AND `STACK_STOPPED`

**Pre-checks before proceeding:**
1. Verify uptime is recent (machine actually rebooted):
   ```bash
   uptime -p
   ```
   If uptime is more than 1 day, the machine was never rebooted. Instruct user to run `sudo reboot` and wait.

2. Verify Docker daemon is active:
   ```bash
   systemctl is-active docker
   ```
   If not `active`, wait 10 seconds and check again. If still failing, consult `02-error-recovery-guide.md` → Section 3.

**Action:**
1. Navigate to the stack directory.
2. Update state memory:
   ```bash
   write_state '{"state": "RUNNING_INIT", "gpu": "<DETECTED_GPU>", "stack": "<STACK_DIR>"}'
   ```
3. Check available system RAM before selecting a profile:
   ```bash
   free -h
   ```
   Note the value in the `total` column of the `Mem:` row.

4. Run the hardware advisor (it is interactive — it will display a hardware report and ask you to choose a profile):
   ```bash
   sudo ./master-deploy.sh init
   ```
   When prompted `Selection [1-3]`, select based on the RAM reading above:
   - **RAM < 16GB** → type `1` (Conservative)
   - **RAM 16GB–64GB** → type `2` (Balanced — Recommended)
   - **RAM > 64GB** → type `3` (Optimal)

5. After `init` completes, verify the tuning file was created successfully.

   On current `main`, the advisor writes to `<stack>/tiger-tuning.env` and `master-deploy.sh` reads the same path — verify with:
   ```bash
   cat ./tiger-tuning.env
   ```
   Expected content (BALANCED profile example): `TIGER_OPTIMIZATION_PROFILE=BALANCED`, `TIGER_CPU_THREADS`, `TIGER_N8N_WORKERS`, `TIGER_OWUI_WORKERS`, `TIGER_LOG_MAX_SIZE`, plus detected hardware fields.

   If the file is missing or empty, `init` has failed. Consult `02-error-recovery-guide.md` and do NOT proceed to `app`.

   > 🗂️ **Legacy-clone fallback:** Pre-fix clones had a path mismatch — `tiger-advisor.sh` wrote `../tiger-tuning.env` relative to the *caller's* `$PWD` (landing at `deployments/tiger-tuning.env`), and `amd/nvidia` `master-deploy.sh` read `./00-pre-flight-advisor/tiger-tuning.env`. Symptom: the line `[Master WARN] Detected [Conservative (Conservative)] mode` at the top of `init` output, and `master-deploy.sh app` silently using CONSERVATIVE despite the user picking another profile. Current `main` fixes both sides — advisor self-locates via `BASH_SOURCE` and writes to `<stack>/tiger-tuning.env`; all `master-deploy.sh` read the same path. If working from an older clone, the tuning file is a gitignored runtime output, so the legal recovery is `cp deployments/tiger-tuning.env <stack>/tiger-tuning.env` — do NOT edit the scripts; pull the fix instead.

   > 💡 **AMD-stack note:** It is normal for `TIGER_GPU_TYPE=Unknown` / `TIGER_VRAM=0` on AMD hosts because `tiger-advisor.sh` relies on `rocm-smi`, which is not installed on the host (ROCm runs inside containers via `/dev/kfd` + `/dev/dri`). This does NOT block deployment.

6. Update state and deploy the application stack:
   ```bash
   write_state '{"state": "DEPLOYING_APP", "gpu": "<DETECTED_GPU>", "stack": "<STACK_DIR>"}'
   sudo ./master-deploy.sh app
   ```
   This step pulls Docker images and starts all service containers. It may take 5–15 minutes on first run.

7. Verify all containers are running:
   ```bash
   docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
   ```
   Confirm containers including `openwebui`, `ollama`, `postgres`, `n8n`, `portainer` are all `Up`.

8. Update state to complete:
   ```bash
   write_state '{"state": "DEPLOYMENT_COMPLETE", "gpu": "<DETECTED_GPU>", "stack": "<STACK_DIR>"}'
   ```

9. **STOP and print this exact message to the user:**

   ---
   🎉 **Deployment complete! The OpenGenie AI Stack is running.**
   
   Your services are now accessible (replace `localhost` with server IP if connecting remotely):
   - **Open WebUI (AI Chat):** http://localhost:8080
   - **Portainer (Container Manager):** http://localhost:9000
   - **n8n (Automation):** http://localhost:5678
   - **pgAdmin (Database):** http://localhost:8000
   - **Grafana (Monitoring):** http://localhost:3000
   - **Qdrant (Vector DB):** http://localhost:6333
   
   If any service is not reachable, tell me:
   **"check deployment health"**
   and I will run a full diagnostic.
   ---

---

### 🟠 STATE 1b: Post-Reboot — SMI Still Not Working
**Condition:** `.agent-state.json` shows `"DRIVER_INSTALLED_PENDING_REBOOT"` BUT `SMI_NO`

**Action:**
1. Check if the driver package is installed but kernel module hasn't loaded:
   ```bash
   dpkg -l | grep nvidia-driver
   lsmod | grep nvidia
   ```
2. If package exists but module is absent, the reboot may not have completed cleanly. Issue another reboot:
   ```bash
   sudo reboot
   ```
3. **STOP and print this exact message to the user:**

   ---
   ⚠️ **The NVIDIA driver is installed but not yet active.**
   
   The machine needs one more reboot.
   1. Run `sudo reboot`.
   2. Wait for restart, then SSH back in.
   3. Start a new conversation and say: **"resume deployment"**
   ---

---

### 🟢 STATE 2: Stack Running (Healthy / Maintenance)
**Condition:** `.agent-state.json` shows `"DEPLOYMENT_COMPLETE"` AND `STACK_RUNNING`

**Action:** Stack is operational. Report status to user with:
```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```
For a fresh reinstall, consult `04-full-purge-procedure.md`.

---

### 🔴 STATE ERROR: Interrupted Mid-Deployment
**Condition:** `.agent-state.json` shows `"INSTALLING_SYSTEM"`, `"RUNNING_INIT"`, or `"DEPLOYING_APP"` (was interrupted)

**Action:**
1. Re-run the state probing commands from Section 3.
2. Determine the furthest completed step, and resume from there.
3. States are designed to be **idempotent**: re-running `system`, `init`, or `app` a second time is safe.

---

## 5. Cross-Reference
- GPU/stack detection → `03-gpu-robustness.md`
- Any command failure → `02-error-recovery-guide.md`
- Full purge / reinstall → `04-full-purge-procedure.md`
