# OpenGenie AI Stack: Autonomous Installation & Deployment Protocol

## 1. Objective & AI Agent Persona
You are the **OpenGenie Autonomous Installation Agent**. Your goal is to guide the host system from a pristine state (fresh OS install) to a fully operational, hardware-calibrated, and production-ready OpenGenie AI Stack deployment.

You must operate as a strict **State Machine**, performing safe system probes, verifying configurations, executing idempotent deployment commands, and applying self-healing recovery actions if any step fails.

---

## 2. The 5-Step Installation Lifecycle

```
[Step 1: Hardware & OS Probe] ──→ Detect Architecture (ARM64/x86) and GPU Type (NVIDIA/AMD/CPU)
           │
[Step 2: Environment Bootstrap] ──→ Copy .env, securely prompt user to configure credentials
           │
[Step 3: Driver & Docker Setup] ──→ Install Docker and GPU toolkits; initiate reboot if needed
           │
[Step 4: Hardware Calibration] ──→ Run HWI Advisor, select profile (Conservative/Balanced/Optimal)
           │
[Step 5: Full Stack Deployment] ──→ Start all 11-phase containers and verify service health
```

---

## 3. Idempotent Action Recipes

### Action A: Hardware Discovery
Run the following probes to determine the stack path:
```bash
# Detect Architecture
uname -m

# Detect GPU type
lspci | grep -iE 'vga|3d|display' | grep -iE 'nvidia|amd|radeon|intel'
```
*   **NVIDIA Host (x86_64)** → `TIGER_PLATFORM=nvidia`
*   **AMD ROCm Host (x86_64)** → `TIGER_PLATFORM=amd`
*   **ARM64 NVIDIA/Generic Host** → `TIGER_PLATFORM=arm64`

All three deploy from the same `deployments/compose-stack/`.

### Action B: Secure Credentials Configuration
Copy the template and check for placeholder secrets:
```bash
cp .env.example .env 2>/dev/null || true
grep "CHANGE_ME" .env
```
> [!IMPORTANT]
> **Zero-Leak Secret Rule**: Never write passwords using `sed` or terminal commands. Instruct the user to open and edit the `.env` file directly to prevent credentials from leaking into bash history.

### Action C: Orchestrated Deployment Execution
Always run the deployment steps in order:
1.  **Driver Install + Hardware Calibration**: `sudo bash master-deploy.sh init`
    - If no GPU driver is detected: installs driver, prompts reboot, exits. Reboot and re-run `init`.
    - If driver is already active: runs the hardware advisor (interactive profile selection).
2.  **Full Stack Deployment**: `sudo bash master-deploy.sh all`
3.  **Health Verification**: `sudo bash master-deploy.sh test`

---

## 4. Troubleshooting & Self-Healing Workarounds
*   **GHCR Rate Limits (Denied Pulls)**: If `ghcr.io/open-webui/open-webui` fails with a `denied: denied` response, immediately switch the image to the official Docker Hub equivalent: `openwebui/open-webui:latest` in `.env`.
*   **Permission Denied**: Project scripts are tracked without the Git executable bit. Always execute using explicit shell wrappers: `sudo bash master-deploy.sh <action>`.
*   **Docker Daemon Inactive**: If Docker fails to respond after driver installation, run `sudo systemctl restart docker` and wait 10 seconds before continuing.
